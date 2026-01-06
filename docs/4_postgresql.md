# PostgreSQL + Vault Database Secrets Engine (Dynamic Credentials)

This step installs PostgreSQL in the cluster (Bitnami chart, no persistence for demo) and configures Vault to issue **dynamic DB credentials** via the `database/` secrets engine.  
It also enables Vault Kubernetes auth and creates the `demo-backend` Kubernetes auth role that can read `database/creds/app-role`.

## 1) Install PostgreSQL (Bitnami) in `default`

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install pg bitnami/postgresql \
  --namespace default \
  --set auth.postgresPassword="postgres-demo-pass" \
  --set auth.database="appdb" \
  --set primary.persistence.enabled=false
````

Wait for Postgres:

```bash
kubectl rollout status statefulset/pg-postgresql

kubectl exec -it "$(kubectl get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')" -- \
  sh -lc 'pg_isready -U postgres'
```

## 2) Quick connectivity check to Vault through Traefik (optional)

If you want to sanity-check Vault access via Traefik from the Podman VM:

```bash
TRAEFIK_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

podman machine ssh -- sh -lc \
  "command curl -sS -H 'Host: vault.local' http://$TRAEFIK_IP/v1/sys/health | head -c 120; echo"
```

## 3) Enable Vault Database secrets engine

Run this wherever your Vault CLI is authenticated (root token in this demo):

```bash
vault secrets enable database || true
```

## 4) Configure the Postgres DB plugin connection

```bash
vault write database/config/pg \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-role" \
  connection_url="postgresql://{{username}}:{{password}}@pg-postgresql.default.svc.cluster.local:5432/postgres?sslmode=disable" \
  username="postgres" \
  password="postgres-demo-pass"
```

## 5) Create a Vault DB role for dynamic credentials

This role will create a short-lived Postgres role and grant it `CONNECT` on `appdb`.

```bash
vault write database/roles/app-role \
  db_name=pg \
  default_ttl="1m" \
  max_ttl="5m" \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE appdb TO \"{{name}}\";" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";"
```

Test issuing credentials:

```bash
vault read database/creds/app-role
```

You should see a lease, username, and password returned.

## 6) Allow Vault to review Kubernetes service account tokens

This binds the Vault service account in the `vault` namespace to the Kubernetes `system:auth-delegator` role.

```bash
kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault 2>/dev/null || true
```

## 7) Enable and configure Vault Kubernetes auth

First enable Kubernetes auth (idempotent):

```bash
vault auth enable kubernetes || true
```

Confirm the Kubernetes service account files exist in the Vault pod:

```bash
kubectl -n vault exec vault-0 -- sh -lc '
ls -la /var/run/secrets/kubernetes.io/serviceaccount/
'
```

Configure the auth method from inside the Vault pod (dev mode root token):

```bash
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
```

## 8) Create policy + Kubernetes role for the backend workload

Policy that grants read access to the dynamic creds endpoint:

```bash
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
```

Verify the role:

```bash
kubectl -n vault exec vault-0 -- sh -lc '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"
vault read auth/kubernetes/role/demo-backend
'
```

## 9) Create the Kubernetes service account for the app

```bash
kubectl create sa demo-backend -n default 2>/dev/null || true
```
