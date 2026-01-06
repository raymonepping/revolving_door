# Traefik: Ingress Controller on Kind (via MetalLB)

With MetalLB in place, we can run Traefik as a `LoadBalancer` service so it gets an IP from the MetalLB pool.

## 1) Install Traefik via Helm

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set service.type=LoadBalancer
````

## 2) Wait for Traefik to be ready

```bash
kubectl -n traefik rollout status deploy/traefik
```

## 3) Get the Traefik LoadBalancer IP

```bash
TRAEFIK_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Traefik IP: $TRAEFIK_IP"
```

## Quick verify (optional)

Show the Traefik service details:

```bash
kubectl -n traefik get svc traefik -o wide
```

You should see an `EXTERNAL-IP` assigned from your MetalLB pool.

```
