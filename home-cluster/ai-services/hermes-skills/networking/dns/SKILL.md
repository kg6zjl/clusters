---
name: dns
description: Debug DNS resolution failures — cluster CoreDNS and external DNS (DNSEndpoint/external-dns). DNS bites this cluster constantly.
category: networking
version: 1.0.0
author: Hermit
---

# DNS Debugging — Home Cluster

**Use when:** A pod, service, URL, or hostname won't resolve ("no such host",
"NAME or service not known", `Could not resolve host`, `Temporary failure in
name resolution`), an ingress host times out, or anything DNS-related breaks.

## Rule of thumb

DNS sits right next to NetworkPolicies in the "always bites us" category.
**If DNS fails, check BOTH in this order:**

1. **NetworkPolicy** — this cluster is default-deny. A pod that can't reach
   CoreDNS is a NetPol egress problem until proven otherwise (see AGENTS.md).
2. **CoreDNS** itself — is it up, and does the pod have the right resolver?
3. **External DNS** — does the public host have a `DNSEndpoint`?

## 1. Cluster DNS (CoreDNS)

- CoreDNS runs in `kube-system`, exposed by Service `kube-dns`.
- Its ClusterIP in this cluster is `10.152.183.10` (kube-dns service).
- Pods get `/etc/resolv.conf` with `nameserver 10.152.183.10` and search
  domains `<ns>.svc.cluster.local svc.cluster.local cluster.local` + `ndots:5`.

### Diagnose from inside the problem namespace

```bash
# What resolver/search domains does the failing pod actually have?
kubectl exec -n <namespace> deploy/<app> -- cat /etc/resolv.conf

# Resolve a service / external host (getent uses libc = what apps use)
kubectl exec -n <namespace> deploy/<app> -- getent hosts <svc-name>.<ns>.svc.cluster.local
kubectl exec -n <namespace> deploy/<app> -- getent hosts github.com

# If dig/nslookup exists, use them; else use getent (always present) or python:
kubectl exec -n <namespace> deploy/<app> -- python3 -c \
  'import socket; print(socket.gethostbyname("github.com"))'

# Is CoreDNS up and healthy?
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
kubectl describe svc kube-dns -n kube-system   # check the ClusterIP
```

### NetPol egress for DNS (the #1 cause)

Every namespace needs an allow-DNS egress to `kube-system` (TCP **and** UDP 53):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: <ns>
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
```

**A/B test (definitive):** from a pod in a namespace with NO NetPol (e.g.
`default`) run the same `getent hosts <target>`. If it resolves there but
times out in the target namespace → **the NetPol is blocking DNS, full stop.**

## 2. External DNS (public hostnames)

Public `*.kube.stevearnett.com` hosts are registered via **external-dns
`DNSEndpoint` CustomResources**, not manually.

- Every service dir that has an `ingressroute.yaml` should also have a
  `dnsendpoint.yaml` with a `CNAME` to `kube.stevearnett.com`.
- `kube.stevearnett.com` resolves to the MetalLB VIP `192.168.1.241`.

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: <svc>
  namespace: kube-system
spec:
  endpoints:
  - dnsName: <svc>.kube.stevearnett.com
    recordType: CNAME
    targets:
    - kube.stevearnett.com
```

### Diagnose external DNS

```bash
dig +short <host>.kube.stevearnett.com        # empty = no record
dig +short kube.stevearnett.com               # should be 192.168.1.241
rg -n "dnsName:" home-cluster/*/dnsendpoint*.yaml   # is a DNSEndpoint defined?
```

**Real incident (do not repeat):** `security.kube.stevearnett.com` had an
IngressRoute but NO DNSEndpoint → the host resolved nowhere externally.
Fix: add the DNSEndpoint **in the same PR** as the IngressRoute.

## 3. Quick checklist

- [ ] Pod `resolv.conf` points at `10.152.183.10` (kube-dns)
- [ ] NetPol allows egress TCP+UDP 53 → `kube-system`
- [ ] CoreDNS pods up; no errors in logs
- [ ] `.svc.cluster.local` name is fully qualified in apps that need it
- [ ] Public host has a `DNSEndpoint` CNAME → `kube.stevearnett.com` (192.168.1.241)
- [ ] A/B test passed from a no-NetPol namespace

**Status:** Active — DNS + NetPol + DNSEndpoint are the usual culprits.