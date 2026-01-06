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
    spec:
      serviceAccountName: demo-backend
      containers:
      - name: app
        image: postgres:16-alpine
        ports:
        - containerPort: 8080
        command: ["/bin/sh","-lc"]
        args:
          - |
            apk add --no-cache netcat-openbsd >/dev/null 2>&1
            CREDS_FILE=/vault/secrets/db.txt
            DB_HOST=pg-postgresql.default.svc.cluster.local
            DB_PORT=5432
            DB_NAME=appdb

            json_escape() { printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

            status_json() {
              if [ ! -f "$CREDS_FILE" ]; then
                echo '{"door":"locked","reason":"NO_CREDS_FILE"}'
                return 1
              fi

              USERNAME="$(grep '^username=' "$CREDS_FILE" | head -1 | cut -d= -f2-)"
              PASSWORD="$(grep '^password=' "$CREDS_FILE" | head -1 | cut -d= -f2-)"
              LEASE_ID="$(grep '^lease_id=' "$CREDS_FILE" | head -1 | cut -d= -f2-)"
              TTL="$(grep '^lease_duration=' "$CREDS_FILE" | head -1 | cut -d= -f2-)"

              if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
                RAW="$(cat "$CREDS_FILE")"
                echo '{"door":"locked","reason":"BAD_CREDS_FORMAT","raw":"'"$(json_escape "$RAW")"'"}'
                return 1
              fi

              export PGPASSWORD="$PASSWORD"
              if psql -h "$DB_HOST" -p "$DB_PORT" -U "$USERNAME" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
                echo '{"door":"opened","username":"'"$(json_escape "$USERNAME")"'","lease_id":"'"$(json_escape "$LEASE_ID")"'","lease_duration":"'"$(json_escape "$TTL")"'"}'
                return 0
              else
                echo '{"door":"locked","reason":"DB_CONNECT_FAILED","username":"'"$(json_escape "$USERNAME")"'","lease_id":"'"$(json_escape "$LEASE_ID")"'","lease_duration":"'"$(json_escape "$TTL")"'"}'
                return 1
              fi
            }

            while true; do
              BODY="$(status_json)"
              CODE=$?
              if [ $CODE -eq 0 ]; then STATUS="HTTP/1.1 200 OK"; else STATUS="HTTP/1.1 503 Service Unavailable"; fi
              LEN="$(printf "%s" "$BODY" | wc -c | tr -d " ")"
              { printf "%s\r\n" "$STATUS";
                printf "Content-Type: application/json; charset=utf-8\r\n";
                printf "Content-Length: %s\r\n" "$LEN";
                printf "\r\n";
                printf "%s" "$BODY";
              } | nc -l -p 8080 -q 1
            done
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

kubectl rollout status deploy/demo-backend
kubectl get pods -l app=demo-backend

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

❯ command curl -sS http://demo.local:18200/api

{"door":"opened","username":"v-kubernet-app-role-9ZQ6fIJUaiJqWxlPewoD-1767627232","lease_id":"database/creds/app-role/lh46y4EjURUxuN21TpIIQWJh","lease_duration":"60"}%    

❯ # Create a deny policy
kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

cat <<HCL | vault policy write deny-db-read -
path "database/creds/app-role" {
  capabilities = ["deny"]
}
HCL
'

Success! Uploaded policy: deny-db-read

kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault write auth/kubernetes/role/demo-backend \
  bound_service_account_names="demo-backend" \
  bound_service_account_namespaces="default" \
  policies="deny-db-read" \
  ttl="24h" \
  audience="https://kubernetes.default.svc.cluster.local"
'

kubectl rollout restart deploy/demo-backend && kubectl rollout status deploy/demo-backend

command curl -sS http://demo.local:18200/api
