Manually create email address secret:
```
kubectl create secret generic cloudflare-dns-token \
  --from-literal=token=<your-token> \
  --namespace=external-dns
```