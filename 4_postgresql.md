helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install pg bitnami/postgresql \
  --namespace default \
  --set auth.postgresPassword="postgres-demo-pass" \
  --set auth.database="appdb" \
  --set primary.persistence.enabled=false

kubectl rollout status statefulset/pg-postgresql
kubectl exec -it "$(kubectl get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')" -- \
  sh -lc 'pg_isready -U postgres'

TRAEFIK_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
podman machine ssh -- sh -lc "command curl -sS -H 'Host: vault.local' http://$TRAEFIK_IP/v1/sys/health | head -c 120; echo"

❯ vault secrets enable database || true

Success! Enabled the database secrets engine at: database/
❯ vault write database/config/pg \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role" \
  connection_url="postgresql://{{username}}:{{password}}@pg-postgresql.default.svc.cluster.local:5432/postgres?sslmode=disable" \
  username="postgres" \
  password="postgres-demo-pass"

Success! Data written to: database/config/pg
❯ vault write database/roles/app-role \
  db_name=pg \
  default_ttl="1m" \
  max_ttl="5m" \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE appdb TO \"{{name}}\";" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";"

Success! Data written to: database/roles/app-role

❯ vault read database/creds/app-role

Key                Value
---                -----
lease_id           database/creds/app-role/yemJ9b4sEoUgUUpWiIUd8G1h
lease_duration     1m
lease_renewable    true
password           fYoqtAxCSI-v0PZEy1BZ
username           v-token-app-role-qtKiQvgh7lw0XEzvr70L-1767626084

kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault 2>/dev/null || true

vault auth enable kubernetes || true

kubectl -n vault exec vault-0 -- sh -lc '
ls -la /var/run/secrets/kubernetes.io/serviceaccount/
'

kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

vault auth enable kubernetes 2>/dev/null || true

vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

vault auth list
'

kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

cat <<HCL | vault policy write app-db-read -
path "database/creds/app-role" {
  capabilities = ["read"]
}
HCL

vault write auth/kubernetes/role/demo-backend \
  bound_service_account_names="demo-backend" \
  bound_service_account_namespaces="default" \
  policies="app-db-read" \
  ttl="24h" \
  audience="https://kubernetes.default.svc.cluster.local"
'

kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

cat <<HCL | vault policy write app-db-read -
path "database/creds/app-role" {
  capabilities = ["read"]
}
HCL

vault write auth/kubernetes/role/demo-backend \
  bound_service_account_names="demo-backend" \
  bound_service_account_namespaces="default" \
  policies="app-db-read" \
  ttl="24h" \
  audience="https://kubernetes.default.svc.cluster.local"
'

kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"
vault read auth/kubernetes/role/demo-backend
'

kubectl create sa demo-backend -n default 2>/dev/null || true
