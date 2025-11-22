Using kustomize for my HomeLab

ssh steve@kube.stevearnett.com
(Password in 1Pass)

Mounted the NAS Shares here:
```
# sudo cat /etc/fstab | grep plex
//192.168.1.176/Media/Movies /mnt/nas/movies cifs username=plex,password=[in 1pass],vers=3.0 0 0
//192.168.1.176/Media/TV /mnt/nas/tv cifs username=plex,password=[in 1pass],vers=3.0 0 0
//192.168.1.176/Media/Torrents /mnt/nas/torrents cifs username=plex,password=[in 1pass],vers=3.0 0 0
```
