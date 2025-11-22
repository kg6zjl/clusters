## Notes
Using the ClusterSecret Operator with Kustomization `.env` files

1. Generate a "root" secret, in this example: `cloudflare-api-creds-root`
1. Then pull the secret out of the root secret when you create the ClusterSecret:
    ```
      data:
        CLOUDFLARE_API_TOKEN: cloudflare-api-creds-root:CLOUDFLARE_API_TOKEN
    ```

## Install
I couldn't get the helm generator for kustomize working, so manual helm install:
```
helm repo add emberstack https://emberstack.github.io/helm-charts
helm repo update
helm upgrade --install reflector emberstack/reflector -n clustersecret --create-namespace
```

## Unknowns
- I'm assuming that I'll need to recreate the root and the ClusterSecret if the secret changes, but untested.
