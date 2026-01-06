# Vault: Deploy via Helm (Dev Mode) + Traefik Ingress

This demo uses Vault in **dev mode** (single pod, in-memory, not for production) plus the **Vault Injector** to support agent injection later.

## Prereqs

- MetalLB installed and working
- Traefik installed and running as `LoadBalancer`
- `TRAEFIK_IP` available in your shell

If you do not have it anymore:

```bash
TRAEFIK_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Traefik IP: $TRAEFIK_IP"
````

## 1) Install Vault via Helm (dev mode)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault vault \
  --repo https://helm.releases.hashicorp.com \
  --namespace vault --create-namespace \
  --set server.dev.enabled=true \
  --set injector.enabled=true
```

## 2) Expose Vault via Traefik Ingress

Create an Ingress for `vault.local`:

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault-ingress
  namespace: vault
spec:
  ingressClassName: traefik
  rules:
  - host: vault.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vault
            port:
              number: 8200
YAML
```

## 3) Verify Vault is reachable through Traefik

This hits Vault’s health endpoint through Traefik using the Host header:

```bash
kubectl run -it --rm curltest --image=curlimages/curl --restart=Never -- \
  curl -sS -i -H "Host: vault.local" "http://$TRAEFIK_IP/v1/sys/health" | head -n 30
```

Expected outcome:

* You get an HTTP response from Vault (dev mode typically reports initialized and unsealed).

## 4) Quick Helm checks

```bash
helm list -A | grep -E '^vault| vault '
helm status vault -n vault
```

```
