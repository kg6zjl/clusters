# Cert
Where did the manifests come from? here:
```
curl -Lo cert-manager.yaml https://github.com/jetstack/cert-manager/releases/download/v1.12.16/cert-manager.yaml
```

Manually create the secrets:
```
kubectl create namespace infra
kubectl create secret generic certmanager-cloudflare-token \
  --from-literal=token=<your-token> \
  --namespace=infra

kubectl create secret generic certmanager-email \
  --from-literal=email=<your-email-address> \
  --namespace=infra
```
Note: there is a duplicate secret in the externaldns namespace for managing cluster dns. 