# ADS-B Tracker (readsb + tar1090)

Tracks aircraft via the Nooelec NESDR SMArt v5 (RTL2838) plugged into `thinkcentre02`
at `/dev/bus/usb/001/004`. Web UI (tar1090 map): `https://adsb.kube.stevearnett.com`.

Uses the [sdr-enthusiasts/docker-adsb-ultrafeeder](https://github.com/sdr-enthusiasts/docker-adsb-ultrafeeder)
image (readsb decoder + tar1090 map + graphs1090) on the `latest` tag.

## SDR assignment

- The Deployment is pinned to `nodeName: thinkcentre02` because that is where the SDR is plugged in.
- The USB device is exposed via a `hostPath` mount of `/dev/bus/usb` with a privileged
  container, matching the existing Home Assistant pattern.
- The RTL-SDR is selected by serial (`READSB_RTLSDR_DEVICE=00000001`, a NESDR SMArt v5).

## Antenna location

The tar1090 map is centered using home coordinates, which are NOT committed to git.
They live in 1Password as item **`adsb`** with fields **`latitude`** and **`longitude`**
(SE landscape coordinates, e.g. `37.7749` and `-122.4194`), synced by the ExternalSecret
Operator into the `adsb-secrets` Secret.

To update: edit the `adsb` item in the `home-cluster` 1Password vault, then wait for ESO
to refresh (1h) or restart the pod. The Deployment then picks up the new `LAT`/`LONG`
env vars.

## Data ports

The Service exposes the Beast feed ports for local consumption:

- `30002` – Beast raw input (feed a consumer)
- `30005` – Beast output (read decoded data from another pod/service)

Example to read the feed from another pod:
`nc adsb-ultrafeeder.adsb.svc.cluster.local 30005`

## Historical data

tar1090 history / timelapse / graphs are persisted on three PVCs
(`adsb-history`, `adsb-timelapse`, `adsb-graphs`).

## How to enable feeding a public aggregator (later)

Currently the receiver runs locally only (no external feed). To feed a network later,
edit the Deployment to add a feeder container (e.g.
[sdr-enthusiasts/docker-adsbexchange](https://github.com/sdr-enthusiasts/docker-adsbexchange))
or a `READSB_NET_CONNECTOR`/`ULTRAFEEDER_CONFIG` entry, and:

1. Request a feeder key/UUID from the aggregator.
2. Add it to 1Password `home-cluster` vault.
3. Extend `external-secrets.yaml` to pull that field into `adsb-secrets`.
4. Reference it via `secretKeyRef` in the Deployment.
5. Update this `network-policy.yaml` to allow egress to the aggregator's host:port.

No secrets are ever committed to this repository.
