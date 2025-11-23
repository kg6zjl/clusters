Config for my HomeLab Cluster

Using Let's Encrypt and cert-manager for TLS and Cloudflare for DNS

```
# Password in 1Pass
ssh steve@kube.stevearnett.com
```

Mounted the NAS Shares here:
```
# sudo cat /etc/fstab | grep plex
//192.168.1.176/Media/Movies /mnt/nas/movies cifs username=plex,password=[in 1pass],vers=3.0 0 0
//192.168.1.176/Media/TV /mnt/nas/tv cifs username=plex,password=[in 1pass],vers=3.0 0 0
//192.168.1.176/Media/Torrents /mnt/nas/torrents cifs username=plex,password=[in 1pass],vers=3.0 0 0
```

---

Added Cloudflared for routing to a silly little web app running in my homelab cluster
