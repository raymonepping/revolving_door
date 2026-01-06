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
            Tip: flip the Vault role policy between <code>app-db-read</code> and <code>deny-db-read</code>, then restart the pod.
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

kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
vault write auth/kubernetes/role/demo-backend \
  bound_service_account_names="demo-backend" \
  bound_service_account_namespaces="default" \
  policies="app-db-read" \
  ttl="24h" \
  audience="https://kubernetes.default.svc.cluster.local"
'
kubectl delete pod -l app=demo-backend


kubectl rollout restart deploy/demo-backend -n default
kubectl rollout status deploy/demo-backend -n default

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
---
apiVersion: batch/v1
kind: Job
metadata:
  name: door-open
  namespace: default
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      serviceAccountName: door-operator
      restartPolicy: Never
      initContainers:
        - name: vault-open
          image: hashicorp/vault:1.20.4
          env:
            - name: VAULT_ADDR
              value: "http://vault.vault.svc:8200"
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

              echo "🧹 Revoking old DB leases so new creds appear fast (optional)"
              vault lease revoke -prefix "database/creds/app-role" || true
      containers:
        - name: restart
          image: bitnami/kubectl:1.35
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -euo pipefail
              echo "🔄 Restarting demo-backend"
              kubectl -n default rollout restart deploy/demo-backend
              kubectl -n default rollout status deploy/demo-backend
              echo "✅ Door open workflow complete"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: door-close
  namespace: default
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      serviceAccountName: door-operator
      restartPolicy: Never
      initContainers:
        - name: vault-close
          image: hashicorp/vault:1.20.4
          env:
            - name: VAULT_ADDR
              value: "http://vault.vault.svc:8200"
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

              echo "🧹 Revoking DB leases so the door locks immediately"
              vault lease revoke -prefix "database/creds/app-role" || true
      containers:
        - name: restart
          image: bitnami/kubectl:1.35
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -euo pipefail
              echo "🔄 Restarting demo-backend"
              kubectl -n default rollout restart deploy/demo-backend
              kubectl -n default rollout status deploy/demo-backend
              echo "✅ Door close workflow complete"
YAML
