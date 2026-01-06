# MetalLB: LoadBalancer IPs for Kind on Podman

This demo runs on a local Kind cluster. Kind does not provide cloud LoadBalancers, so we add **MetalLB** to allocate external IPs for Services of type `LoadBalancer`.

## 1) Create and label the namespace

```bash
kubectl create namespace metallb-system 2>/dev/null || true

kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
````

## 2) Install MetalLB via Helm

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm install metallb metallb/metallb -n metallb-system
```

Wait for the controller to be ready:

```bash
kubectl -n metallb-system rollout status deploy/controller
kubectl -n metallb-system get pods -o wide
```

## 3) Determine the Podman network range

MetalLB needs an IP range that is reachable from the network your Kind nodes run on.

Inspect the `kind` Podman network:

```bash
podman network ls
podman network inspect kind
```

Pick a free IP range within that network. In this demo, we use:

* `10.89.1.200-10.89.1.250`

## 4) Create an IPAddressPool and L2Advertisement

Apply the MetalLB configuration:

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: demo-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.89.1.200-10.89.1.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: demo-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - demo-pool
YAML
```

Verify resources:

```bash
kubectl -n metallb-system get ipaddresspools,l2advertisements
```

Expected output should include:

* `ipaddresspool.metallb.io/demo-pool`
* `l2advertisement.metallb.io/demo-l2`

## 5) Validate with a test LoadBalancer Service

Create a simple test deployment and expose it as a `LoadBalancer` service:

```bash
kubectl create deployment lbtest --image=nginx:1.27-alpine
kubectl expose deployment lbtest --port 80 --type LoadBalancer --name lbtest-svc
```

Check if an external IP is assigned:

```bash
kubectl get svc lbtest-svc -o wide
```

### Test from the Podman VM (podman machine)

```bash
LBIP="$(kubectl get svc lbtest-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
podman machine ssh -- curl -sS "http://$LBIP" | head
```

### Test from inside the cluster

```bash
LBIP="$(kubectl get svc lbtest-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
kubectl run -it --rm curltest --image=curlimages/curl --restart=Never -- \
  curl -sS --connect-timeout 2 --max-time 5 "http://$LBIP" | head
```

## Cleanup (optional)

```bash
kubectl delete svc lbtest-svc
kubectl delete deploy lbtest
```
