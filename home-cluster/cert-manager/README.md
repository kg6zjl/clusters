Manual Install

```
 # on microk8s host
microk8s enable cert-manager
# from laptop
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.crds.yaml
```

# NAS Notes
There is a cronjob that uploads my wildcard cert to /cert on the NAS, which is then symlinked to:
```
root@DXP2800-D460:/ugreen/.config/ssl/certs/*.stevearnett.com# pwd
/ugreen/.config/ssl/certs/*.stevearnett.com
```
from `/volume2/cert/`
