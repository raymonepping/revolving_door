# 5. Backend Deployment (Vault Agent Injection + “Revolving Door” API)

This step deploys the `demo-backend` workload into Kubernetes and uses **Vault Agent Injection** to write **dynamic PostgreSQL credentials** to:

- `/vault/secrets/db.txt`

The backend exposes a small HTTP API at:

- `http://demo.local:18200/api`

It returns:

- `{"door":"opened", ...}` when it can read injected creds and successfully connect to Postgres
- `{"door":"locked", "reason": ...}` when creds are missing or DB access fails

This is the foundation for the “revolving door” demo: flipping the Vault policy on the Kubernetes auth role and restarting the pod changes whether the app can obtain DB creds.

---

## Prerequisites

Before you run this step, you should already have:

- MetalLB + Traefik installed and working
- Vault installed (injector enabled)
- PostgreSQL installed (`pg-postgresql` in `default`)
- Vault configured:
  - `database/` secrets engine enabled and configured
  - `database/roles/app-role` created
  - Kubernetes auth enabled and configured
  - Kubernetes auth role `demo-backend` exists and is bound to ServiceAccount `demo-backend`
  - `app-db-read` policy exists and allows `read` on `database/creds/app-role`

---

## 1) Deploy the backend (ConfigMap + Deployment + Service)

The backend runs as a single Deployment (`demo-backend`) with:

- `serviceAccountName: demo-backend`
- Vault injector annotations that render DB creds to `/vault/secrets/db.txt`
- App code mounted from a ConfigMap (`demo-backend-app`) into `/app/app.py`

### 1.1 Apply the app code ConfigMap

This is the backend logic that:
- serves `/api` (door state)
- serves `/healthz` (always OK, independent of door state)

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-backend-app
  namespace: default
data:
  app.py: |
    import json
    import os
    import subprocess
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    CREDS_FILE = "/vault/secrets/db.txt"
    DB_HOST = "pg-postgresql.default.svc.cluster.local"
    DB_PORT = "5432"
    DB_NAME = "appdb"

    def parse_kv(text: str) -> dict:
      out = {}
      for line in text.splitlines():
        if "=" in line:
          k, v = line.split("=", 1)
          out[k.strip()] = v.strip()
      return out

    def check_db(username: str, password: str) -> bool:
      env = os.environ.copy()
      env["PGPASSWORD"] = password
      cmd = [
        "psql",
        "-h", DB_HOST,
        "-p", DB_PORT,
        "-U", username,
        "-d", DB_NAME,
        "-tAc", "SELECT 1",
      ]
      p = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
      return p.returncode == 0

    def status_payload():
      if not os.path.exists(CREDS_FILE):
        return 503, {"door": "locked", "reason": "NO_CREDS_FILE"}

      raw = open(CREDS_FILE, "r", encoding="utf-8").read()
      kv = parse_kv(raw)

      user = kv.get("username", "")
      pwd = kv.get("password", "")
      lease_id = kv.get("lease_id", "")
      ttl = kv.get("lease_duration", "")

      if not user or not pwd:
        return 503, {"door": "locked", "reason": "BAD_CREDS_FORMAT"}

      try:
        ok = check_db(user, pwd)
      except Exception as e:
        return 503, {"door": "locked", "reason": "DB_CHECK_ERROR", "error": str(e)}

      if ok:
        return 200, {"door": "opened", "username": user, "lease_id": lease_id, "lease_duration": ttl}
      return 503, {"door": "locked", "reason": "DB_CONNECT_FAILED", "username": user, "lease_id": lease_id, "lease_duration": ttl}

    class Handler(BaseHTTPRequestHandler):
      def do_GET(self):
        if self.path == "/healthz":
          body = b"ok\n"
          self.send_response(200)
          self.send_header("Content-Type", "text/plain; charset=utf-8")
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)
          return

        if self.path.startswith("/api"):
          code, payload = status_payload()
          body = (json.dumps(payload) + "\n").encode("utf-8")
          self.send_response(code)
          self.send_header("Content-Type", "application/json; charset=utf-8")
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)
          return

        self.send_response(404)
        self.end_headers()

      def log_message(self, *_args, **_kwargs):
        return

    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
YAML
````

### 1.2 Apply the Deployment + Service

Important annotations:

* `vault.hashicorp.com/agent-inject: "true"`
* `vault.hashicorp.com/role: "demo-backend"`
* `vault.hashicorp.com/agent-inject-secret-db.txt: database/creds/app-role`
* template writes `username=...`, `password=...`, lease fields to `/vault/secrets/db.txt`

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-backend
  namespace: default
  labels:
    app: demo-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-backend
  template:
    metadata:
      labels:
        app: demo-backend
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "demo-backend"
        vault.hashicorp.com/agent-inject-secret-db.txt: "database/creds/app-role"
        vault.hashicorp.com/agent-inject-template-db.txt: |
          {{- with secret "database/creds/app-role" -}}
          username={{ .Data.username }}
          password={{ .Data.password }}
          lease_id={{ .LeaseID }}
          lease_duration={{ .LeaseDuration }}
          renewable={{ .Renewable }}
          {{- end -}}
        vault.hashicorp.com/agent-pre-populate: "false"
    spec:
      serviceAccountName: demo-backend
      containers:
      - name: app
        image: python:3.12-alpine
        command: ["/bin/sh","-lc"]
        args:
          - apk add --no-cache postgresql-client >/dev/null 2>&1 || true; python /app/app.py
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 2
          timeoutSeconds: 1
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 2
        volumeMounts:
        - name: app-code
          mountPath: /app/app.py
          subPath: app.py
          readOnly: true
      volumes:
      - name: app-code
        configMap:
          name: demo-backend-app
---
apiVersion: v1
kind: Service
metadata:
  name: demo-backend
  namespace: default
spec:
  selector:
    app: demo-backend
  ports:
  - name: http
    port: 80
    targetPort: 8080
YAML
```

Wait for rollout:

```bash
kubectl rollout status deploy/demo-backend
kubectl get pods -l app=demo-backend -o wide
```

---

## 2) Expose `/api` via Traefik Ingress

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-api-ingress
  namespace: default
spec:
  ingressClassName: traefik
  rules:
  - host: demo.local
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: demo-backend
            port:
              number: 80
YAML
```

Test:

```bash
command curl -sS http://demo.local:18200/api
```

Expected when open:

```json
{"door":"opened","username":"...","lease_id":"...","lease_duration":"60"}
```

Expected when locked:

```json
{"door":"locked","reason":"NO_CREDS_FILE"}
```

---

## 3) Verify Vault Agent injection inside the Pod

Your **Pod spec** should show two containers:

* `app` (your backend)
* `vault-agent` (injected by Vault injector)

And two important EmptyDir volumes (in-memory):

* `home-sidecar` (Vault Agent home)
* `vault-secrets` (where `/vault/secrets/db.txt` is rendered)

### 3.1 Confirm creds file presence

```bash
POD="$(kubectl -n default get pod -l app=demo-backend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n default exec "$POD" -c app -- sh -lc '
ls -la /vault/secrets || true
echo "----"
cat /vault/secrets/db.txt 2>/dev/null || echo "NO_CREDS_FILE"
'
```

### 3.2 Check Vault Agent logs

```bash
kubectl -n default logs "$POD" -c vault-agent --tail=200
```

Typical error when the door is locked:

* `403 permission denied` on `database/creds/app-role`

---

## 4) “Door” behavior (what controls open vs locked)

The only thing that changes the door state is whether the Vault Agent is allowed to read:

* `database/creds/app-role`

In this demo, you flip the Vault policy assigned to the Kubernetes auth role:

* `app-db-read`  -> allows read -> creds render -> door opens
* `deny-db-read` -> denies read  -> creds do not render -> door locks

After changing the role policy, you restart the backend so Vault Agent re-auths and re-templates.

---

## Troubleshooting

### Door is locked but you expected open

1. Verify the Vault role has `policies="app-db-read"`:

```bash
kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
vault read auth/kubernetes/role/demo-backend
'
```

2. Check Vault Agent logs for 403:

```bash
kubectl -n default logs "$POD" -c vault-agent --tail=200
```

3. Confirm `/vault/secrets/db.txt` exists:

```bash
kubectl -n default exec "$POD" -c app -- sh -lc 'test -f /vault/secrets/db.txt && echo OK || echo NO_CREDS_FILE'
```

### Door is open but DB connect fails

You will see:

* `{"door":"locked","reason":"DB_CONNECT_FAILED", ...}`

Check Postgres is ready:

```bash
kubectl exec -it "$(kubectl get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')" -- \
  sh -lc 'pg_isready -U postgres'
```

Then validate the role creation/grants in the Vault DB role configuration from the Postgres/Vault step.

```
