kubectl create namespace metallb-system 2>/dev/null || true

kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm install metallb metallb/metallb -n metallb-system

kubectl -n metallb-system rollout status deploy/controller
kubectl -n metallb-system get pods -o wide

podman network ls && podman network inspect kind

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

❯ kubectl -n metallb-system get ipaddresspools,l2advertisements

NAME                                 AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
ipaddresspool.metallb.io/demo-pool   true          false             ["10.89.1.200-10.89.1.250"]

NAME                                 IPADDRESSPOOLS   IPADDRESSPOOL SELECTORS   INTERFACES
l2advertisement.metallb.io/demo-l2   ["demo-pool"] 

kubectl create deployment lbtest --image=nginx:1.27-alpine
kubectl expose deployment lbtest --port 80 --type LoadBalancer --name lbtest-svc

kubectl get svc lbtest-svc -o wide

LBIP="$(kubectl get svc lbtest-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
podman machine ssh -- curl -sS "http://$LBIP" | head

LBIP="$(kubectl get svc lbtest-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
kubectl run -it --rm curltest --image=curlimages/curl --restart=Never -- \
  curl -sS --connect-timeout 2 --max-time 5 "http://$LBIP" | head
