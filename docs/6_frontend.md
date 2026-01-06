# 6. Frontend + Door Operator (UI + Open/Close Workflows)

This step adds:

- A tiny NGINX frontend that polls `/api` every second and shows **🔓 OPENED** or **🔒 LOCKED**
- A “door operator” mechanism in Kubernetes to flip the Vault Kubernetes auth role policy and restart the backend

Prereqs:

- Kind cluster is up
- MetalLB is working
- Traefik is installed and has an external IP
- Vault is installed (dev mode is fine for this demo) and Kubernetes auth is configured
- PostgreSQL is installed and Vault Database secrets engine is configured
- `demo-backend` is deployed and reachable via `http://demo.local:18200/api`

---

## 1) Frontend architecture (what it is)

The frontend is intentionally simple:

- One Deployment: `vault-door-frontend` (1 replica)
- One container: `nginx:1.27-alpine`
- One ConfigMap: `vault-door-frontend` that contains `index.html`
- The ConfigMap is mounted into NGINX at:
  - `/usr/share/nginx/html/index.html` (via `subPath: index.html`)
- No custom ServiceAccount, no Vault injection, no sidecars
  - The Pod runs under `serviceAccountName: default`

This matches the observed specs:

- Deployment selector: `app=vault-door-frontend`
- Pod label: `app=vault-door-frontend`
- Volume: `web` from ConfigMap `vault-door-frontend`
- VolumeMount: `/usr/share/nginx/html/index.html` (read-only)

---

## 2) Deploy the frontend (ConfigMap + Deployment + Service)

This creates a ConfigMap with `index.html`, mounts it into NGINX, and exposes it with a Service.

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-door-frontend
  namespace: default
data:
  index.html: |
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Vault Door</title>
      <style>
        body { font-family: -apple-system, system-ui, Segoe UI, Roboto, Helvetica, Arial, sans-serif; margin: 0; background: #0b1020; color: #e8eefc; }
        .wrap { max-width: 860px; margin: 0 auto; padding: 36px 18px; }
        .card { background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.10); border-radius: 16px; padding: 22px; box-shadow: 0 12px 30px rgba(0,0,0,0.35); }
        .row { display: flex; gap: 14px; align-items: center; justify-content: space-between; flex-wrap: wrap; }
        h1 { margin: 0 0 10px; font-size: 28px; letter-spacing: 0.4px; }
        .status { font-size: 18px; font-weight: 650; }
        .pill { display: inline-block; padding: 6px 10px; border-radius: 999px; font-size: 13px; border: 1px solid rgba(255,255,255,0.12); background: rgba(255,255,255,0.05); }
        .ok { border-color: rgba(52, 211, 153, 0.45); background: rgba(52, 211, 153, 0.12); }
        .bad { border-color: rgba(248, 113, 113, 0.45); background: rgba(248, 113, 113, 0.12); }
        .grid { display: grid; grid-template-columns: 220px 1fr; gap: 10px 16px; margin-top: 18px; }
        .k { opacity: 0.75; }
        .v { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
        .footer { margin-top: 12px; opacity: 0.7; font-size: 12px; }
        button { cursor: pointer; border-radius: 12px; border: 1px solid rgba(255,255,255,0.14); background: rgba(255,255,255,0.08); color: #e8eefc; padding: 10px 12px; }
        button:hover { background: rgba(255,255,255,0.12); }
        .small { opacity: 0.8; font-size: 13px; }
      </style>
    </head>
    <body>
      <div class="wrap">
        <h1>Vault Door</h1>
        <div class="card">
          <div class="row">
            <div>
              <div id="status" class="status">Checking…</div>
              <div id="hint" class="small">This page polls <code>/api</code> for state.</div>
            </div>
            <div class="row">
              <span id="pill" class="pill">…</span>
              <button onclick="loadState()">Refresh</button>
            </div>
          </div>

          <div id="details" class="grid" style="display:none;">
            <div class="k">username</div><div id="username" class="v"></div>
            <div class="k">lease_id</div><div id="lease_id" class="v"></div>
            <div class="k">lease_duration</div><div id="lease_duration" class="v"></div>
            <div class="k">reason</div><div id="reason" class="v"></div>
          </div>

          <div class="footer">
            Tip: flip the Vault role policy between <code>app-db-read</code> and <code>deny-db-read</code>, then restart the backend pod.
          </div>
        </div>
      </div>

      <script>
        const el = (id) => document.getElementById(id);

        function setLocked(reason) {
          el("status").textContent = "🔒 Door is LOCKED";
          el("pill").textContent = "LOCKED";
          el("pill").className = "pill bad";
          el("details").style.display = "grid";
          el("username").textContent = "-";
          el("lease_id").textContent = "-";
          el("lease_duration").textContent = "-";
          el("reason").textContent = reason || "-";
        }

        function setOpened(data) {
          el("status").textContent = "🔓 Door is OPENED";
          el("pill").textContent = "OPENED";
          el("pill").className = "pill ok";
          el("details").style.display = "grid";
          el("username").textContent = data.username || "-";
          el("lease_id").textContent = data.lease_id || "-";
          el("lease_duration").textContent = data.lease_duration || "-";
          el("reason").textContent = data.reason || "-";
        }

        async function loadState() {
          try {
            const res = await fetch("/api", { cache: "no-store" });
            const text = await res.text();
            let data = {};
            try { data = JSON.parse(text); } catch(e) { data = { door: "locked", reason: "BAD_JSON", raw: text }; }
            if (res.ok && data.door === "opened") setOpened(data);
            else setLocked(data.reason || ("HTTP_" + res.status));
          } catch (e) {
            setLocked("FRONTEND_FETCH_FAILED");
          }
        }

        loadState();
        setInterval(loadState, 1000);
      </script>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-door-frontend
  namespace: default
  labels:
    app: vault-door-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault-door-frontend
  template:
    metadata:
      labels:
        app: vault-door-frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: web
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
          readOnly: true
      volumes:
      - name: web
        configMap:
          name: vault-door-frontend
---
apiVersion: v1
kind: Service
metadata:
  name: vault-door-frontend
  namespace: default
spec:
  selector:
    app: vault-door-frontend
  ports:
  - name: http
    port: 80
    targetPort: 80
YAML
````

Verify rollout:

```bash
kubectl rollout status deploy/vault-door-frontend -n default
kubectl get pods -l app=vault-door-frontend -n default -o wide
```

---

## 3) One Ingress for both `/` and `/api`

This routes:

* `/api` to `demo-backend`
* `/` to `vault-door-frontend`

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
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
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vault-door-frontend
            port:
              number: 80
YAML
```

Quick checks:

```bash
command curl -sS http://demo.local:18200/api
# UI:
# http://demo.local:18200/
```

---

## 4) Door Operator (open/close workflows)

You already have scripts in `./scripts/` that implement:

* `open` -> set role policy to `app-db-read`, revoke DB leases, restart backend, wait for rollout
* `close` -> set role policy to `deny-db-read`, revoke DB leases, restart backend, wait for rollout
* `toggle` -> decides open vs close based on current `/api` state

This section documents the Kubernetes pieces those scripts rely on.

### 4.1 Demo-only note

This approach uses a Kubernetes Secret containing the Vault root token. That is intentionally demo-only.
In a real setup you would replace this with a tightly scoped Vault token, and likely avoid storing it in-cluster at all.

### 4.2 RBAC + token Secret

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-root-token
  namespace: default
type: Opaque
stringData:
  token: root
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: door-operator
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: door-operator
  namespace: default
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get","list","watch","patch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: door-operator
  namespace: default
subjects:
  - kind: ServiceAccount
    name: door-operator
    namespace: default
roleRef:
  kind: Role
  name: door-operator
  apiGroup: rbac.authorization.k8s.io
YAML
```

### 4.3 Create operator CronJobs (matches the running cluster)

Your `revolving_door.sh` triggers Jobs from these CronJobs:

* `kubectl create job --from=cronjob/door-open ...`
* `kubectl create job --from=cronjob/door-close ...`

So the operator definitions are stored as CronJobs that are suspended and effectively “manual only”.

Key design choices (as deployed):

* `suspend: true` (never auto-runs)
* `schedule: 0 0 1 1 *` (once per year, but suspended anyway)
* `initContainers` do the work:

  * `vault-open|vault-close`: update Vault auth role policy and revoke DB leases
  * `restart`: rollout restart backend
  * `status`: wait for rollout status
* A final `done` container runs `kubectl version --client=true` to complete the pod
* `backoffLimit: 0` so failures fail fast
* `concurrencyPolicy: Forbid` so you cannot overlap door operations
* `ttlSecondsAfterFinished: 300` so Jobs are cleaned up

Apply:

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: door-open
  namespace: default
spec:
  schedule: "0 0 1 1 *"
  suspend: true
  concurrencyPolicy: Forbid
  failedJobsHistoryLimit: 1
  successfulJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: door-operator
          restartPolicy: Never
          initContainers:
            - name: vault-open
              image: hashicorp/vault:1.20.4
              env:
                - name: VAULT_ADDR
                  value: http://vault.vault.svc:8200
                - name: VAULT_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: vault-root-token
                      key: token
              command: ["/bin/sh","-lc"]
              args:
                - |
                  set -euo pipefail
                  echo "🔓 Setting Vault k8s role policy to app-db-read"
                  vault write auth/kubernetes/role/demo-backend \
                    bound_service_account_names="demo-backend" \
                    bound_service_account_namespaces="default" \
                    policies="app-db-read" \
                    ttl="24h" \
                    audience="https://kubernetes.default.svc.cluster.local"
                  echo "♻️ Revoking DB leases (forces fresh creds)"
                  vault lease revoke -prefix "database/creds/app-role" || true
            - name: restart
              image: rancher/kubectl:v1.35.0
              command: ["kubectl"]
              args: ["-n","default","rollout","restart","deploy/demo-backend"]
            - name: status
              image: rancher/kubectl:v1.35.0
              command: ["kubectl"]
              args: ["-n","default","rollout","status","deploy/demo-backend","--timeout=180s"]
          containers:
            - name: done
              image: rancher/kubectl:v1.35.0
              command: ["kubectl"]
              args: ["version","--client=true"]
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: door-close
  namespace: default
spec:
  schedule: "0 0 1 1 *"
  suspend: true
  concurrencyPolicy: Forbid
  failedJobsHistoryLimit: 1
  successfulJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: door-operator
          restartPolicy: Never
          initContainers:
            - name: vault-close
              image: hashicorp/vault:1.20.4
              env:
                - name: VAULT_ADDR
                  value: http://vault.vault.svc:8200
                - name: VAULT_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: vault-root-token
                      key: token
              command: ["/bin/sh","-lc"]
              args:
                - |
                  set -euo pipefail
                  echo "🔒 Setting Vault k8s role policy to deny-db-read"
                  vault write auth/kubernetes/role/demo-backend \
                    bound_service_account_names="demo-backend" \
                    bound_service_account_namespaces="default" \
                    policies="deny-db-read" \
                    ttl="24h" \
                    audience="https://kubernetes.default.svc.cluster.local"
                  echo "🧨 Revoking DB leases (locks immediately)"
                  vault lease revoke -prefix "database/creds/app-role" || true
            - name: restart
              image: rancher/kubectl:v1.35.0
              command: ["kubectl"]
              args: ["-n","default","rollout","restart","deploy/demo-backend"]
            - name: status
              image: rancher/kubectl:v1.35.0
              command: ["kubectl"]
              args: ["-n","default","rollout","status","deploy/demo-backend","--timeout=180s"]
          containers:
            - name: done
              image: rancher/kubectl:v1.35.0
              command: ["kubectl"]
              args: ["version","--client=true"]
YAML
```

Verify:

```bash
kubectl -n default get cronjobs door-open door-close
```

---

## 5) Run the demo

Open the door:

```bash
./scripts/revolving_door.sh open
./scripts/revolving_door.sh status
```

Close the door:

```bash
./scripts/revolving_door.sh close
./scripts/revolving_door.sh status
```

Toggle based on current state:

```bash
./scripts/revolving_door.sh toggle
```

UI:

* `http://demo.local:18200/`

API:

* `http://demo.local:18200/api`

---

## 6) Troubleshooting

### Frontend is up, but UI shows LOCKED forever

Check the API directly:

```bash
command curl -sS -i http://demo.local:18200/api | head -n 20
```

Check the backend pod and Vault Agent:

```bash
kubectl -n default get pods -l app=demo-backend -o wide
POD="$(kubectl -n default get pod -l app=demo-backend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n default logs "$POD" -c vault-agent --tail=200
```

### `revolving_door.sh` says CronJob not found

Confirm the CronJobs exist:

```bash
kubectl -n default get cronjobs | grep -E '^door-open|^door-close'
```

If they do not exist, re-apply section 4.3.

### Door open/close Job fails

List Jobs and inspect the most recent one:

```bash
kubectl -n default get jobs --sort-by=.metadata.creationTimestamp | tail
kubectl -n default describe job/<job-name>
```

Check logs per initContainer:

```bash
kubectl -n default logs job/<job-name> -c vault-open   --tail=200
kubectl -n default logs job/<job-name> -c vault-close  --tail=200
kubectl -n default logs job/<job-name> -c restart      --tail=200
kubectl -n default logs job/<job-name> -c status       --tail=200
kubectl -n default logs job/<job-name> -c done         --tail=200
```

Common root causes:

* Vault policy write fails (bad `VAULT_ADDR`, missing token, auth issues)
* Backend rollout fails (deployment not found, RBAC missing verbs)
* DB lease revoke fails (usually safe, it is `|| true`, but useful to see output)
