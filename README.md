# Vault Revolving Door Demo (Kubernetes + Vault + DB creds)

This repo is a small, hands-on demo that shows a simple idea:

- When the Vault role policy allows DB creds, the backend can fetch dynamic credentials and the “door” is **OPEN** 🔓
- When the Vault role policy denies DB creds (and leases are revoked), the backend loses access and the “door” is **LOCKED** 🔒

The door is controlled by running Kubernetes CronJobs as one-off Jobs. Those Jobs:

1) update the Vault Kubernetes auth role policy for the backend service account  
2) revoke database leases to force immediate effect  
3) restart the backend deployment so the Vault Agent sidecar re-auths and re-templates

---

## Repository layout

```text
./
├── docs/
│   ├── 1_metallb.md
│   ├── 2_traefik.md
│   ├── 3_vault.md
│   ├── 4_postgresql.md
│   ├── 5_backend.md
│   ├── 6_frontend.md
│   ├── FOLDER_TREE.md
│   └── README.md
├── scripts/
│   ├── close_door.sh
│   ├── open_door.sh
│   ├── revolving_door.sh
│   └── toggle.sh
├── kind-podman-multinode.yaml
├── .dockerignore
└── LICENSE
````

The `docs/` folder is the step-by-step build guide. We will review those files later.

The `scripts/` folder is the operator UX for the demo.

---

## What the demo does

### Components (high level)

- Kubernetes cluster: Kind running on Podman, multi-node
- MetalLB: provides LoadBalancer support in Kind
- Traefik: ingress / routing
- Vault: Kubernetes auth + database secrets engine
- PostgreSQL: backing database for dynamic credentials
- Backend: reads `/vault/secrets/db.txt` (rendered by Vault Agent) and exposes `/api`
- Frontend: polls `/api` and shows OPENED or LOCKED

### Door logic (what you see)

- `GET /api` returns JSON containing:

  - `door: opened` plus `username`, `lease_id`, `lease_duration`
  - or `door: locked` plus `reason` (commonly `NO_CREDS_FILE`)

---

## Prerequisites

You will need:

- `kubectl`
- `kind`
- `podman` (this repo is tuned for Kind on Podman)
- `curl`
- `bash`

Optional but nice:

- `python3` (used by `revolving_door.sh` for JSON parsing, it has a fallback if not installed)

---

## Quick start

### 1) Bring up the cluster

Use the provided Kind config:

```bash
kind create cluster --name demo --config kind-podman-multinode.yaml
kubectl cluster-info
```

### 2) Follow the docs in order

The docs are numbered for a reason:

```text
docs/1_metallb.md
docs/2_traefik.md
docs/3_vault.md
docs/4_postgresql.md
docs/5_backend.md
docs/6_frontend.md
```

At the end of that flow you should have:

- a reachable demo endpoint
- a backend deployment with Vault Agent injection enabled
- CronJobs that can “open” and “close” the door by changing the Vault role policy

---

## Using the door controls

### Status

```bash
./scripts/revolving_door.sh status
```

Example output:

- `🔓 Door is OPEN (user: ..., ttl: 60s)`
- `🔒 Door is LOCKED (reason: NO_CREDS_FILE)`

### Open the door

```bash
./scripts/revolving_door.sh open
```

### Close the door

```bash
./scripts/revolving_door.sh close
```

### Toggle (cycle)

Toggle means: if locked then open, if opened then close.

```bash
./scripts/revolving_door.sh toggle
# or
./scripts/revolving_door.sh cycle
```

### Verbose mode

Verbose prints the polling loop while it waits for the new state.

```bash
./scripts/revolving_door.sh open --verbose
./scripts/revolving_door.sh close --verbose
```

---

## Convenience aliases (optional)

If you use zsh, add these to `~/.zshrc`:

```bash
alias door='./scripts/revolving_door.sh'
alias door-open='./scripts/revolving_door.sh open'
alias door-close='./scripts/revolving_door.sh close'
alias door-toggle='./scripts/revolving_door.sh toggle'
alias door-status='./scripts/revolving_door.sh status'
```

Reload your shell:

```bash
source ~/.zshrc
```

---

## Useful kubectl commands

### Watch backend pods

```bash
kubectl -n default get pods -l app=demo-backend -w
```

### Check Vault Agent logs in the backend pod

```bash
POD="$(kubectl -n default get pods -l app=demo-backend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n default logs "$POD" -c vault-agent --tail=200
```

### Confirm whether the injected creds file exists

```bash
POD="$(kubectl -n default get pods -l app=demo-backend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n default exec "$POD" -c app -- sh -lc 'ls -l /vault/secrets || true; echo "----"; test -f /vault/secrets/db.txt && cat /vault/secrets/db.txt || echo "NO_CREDS_FILE"'
```

---

## Troubleshooting

### Door status shows `http: 000`

That typically means the demo URL is not reachable from your machine (routing, ingress, DNS, or the service is not exposed yet).

- Verify your ingress / LB setup from `docs/2_traefik.md` and `docs/1_metallb.md`
- Confirm the backend service and ingress are up
- Try curling the service directly from inside the cluster as a sanity check

### Door stays OPEN after close

If the door should be locked but it keeps returning OPEN, one of these is usually true:

- the backend pod did not restart (or traffic is still hitting the old pod)
- the app is not actually relying on the injected file, or it caches old credentials
- the DB user is still valid because leases were not revoked, or the app is not forced to refresh

Check:

- `kubectl rollout status deploy/demo-backend -n default`
- Vault Agent logs for 403s (permission denied) when locked
- The file `/vault/secrets/db.txt` should be missing or not readable when locked

### Vault Agent shows `403 permission denied` but `/api` still returns OPEN

That can happen if the backend still has a previously acquired DB session and does not require fresh creds for the request path.
In this demo, “LOCKED” is strongest when:

- the app reads the injected file on each request (or on a short interval)
- you revoke leases and restart the pod (already implemented)

---

## Security notes

This demo typically uses elevated privileges to keep the flow obvious (for example a root token stored as a Kubernetes secret for the operator job).
That is fine for a demo, but do not copy that into production.

---

## License

See `LICENSE`.

```
