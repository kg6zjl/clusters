Manually create the secret:
```
kubectl create namespace external-dns
kubectl create secret generic cloudflare-dns-token \
  --from-literal=token=<your-token> \
  --namespace=external-dns
  
```
Note: this same secret is duplicated in cert-manager namespace. Use https://github.com/EmberStack/kubernetes-reflector or something to automate this someday.