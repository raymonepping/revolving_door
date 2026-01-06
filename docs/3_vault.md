helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault vault \
  --repo https://helm.releases.hashicorp.com \
  --namespace vault --create-namespace \
  --set server.dev.enabled=true \
  --set injector.enabled=true

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

kubectl run -it --rm curltest --image=curlimages/curl --restart=Never -- \
  curl -sS -i -H "Host: vault.local" "http://$TRAEFIK_IP/v1/sys/health" | head -n 30

helm list -A | grep -E '^vault| vault '
helm status vault -n vault

