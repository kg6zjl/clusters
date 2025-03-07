Manually create the secret:
```
kubectl create secret generic externaldns-cloudflare-token \
  --from-literal=cloudflare-api-token=<your-cloudflare-api-token> \
  --namespace=external-dns
```