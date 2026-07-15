---
name: check-cluster-health
description: Use when investigating whether the homelab's Kubernetes cluster and its dependencies are healthy — after a reboot, before/after a Flux deploy, when an app seems down or slow, or for a periodic deep sweep. Triggers include "check cluster health", "is everything okay", "deep health check", "what's broken", "cluster status".
disable-model-invocation: true
---

# Check Cluster Health

## Overview

A single symptom here is often the tail of a much longer chain: an NFS backend
outage looks like "Grafana won't load," a decommissioned node looks like
"alertmanager stuck Pending," a stuck Helm release looks like "my config change
isn't applying" even though the pod is `Running`. `kubectl get pods -A` alone
misses most of this. Run this sweep top to bottom — each layer catches a class
of failure the one above it hides.

For a full pass, consider dispatching it to a subagent so the raw command
output doesn't fill your main context — have it report back the anomalies
**and** the raw numbers needed for the stats overview (disk %, load average,
pod counts, resource-limit outliers). Only the top-level agent should do the
final reporting (see **Report Format** below) — a dispatched subagent can't
call `AskUserQuestion`, so it must hand findings back rather than ask the
user anything itself.

Also available as `/healthcheck`.

## 1. Flux — is GitOps actually converging?

```bash
flux get kustomizations -A
flux get helmreleases -A
flux get sources git -A     # Gitea pull path healthy?
flux get sources helm -A    # any HelmRepository 404ing/unreachable?
```

Look for `READY: False`, unexpected `SUSPENDED: True`, or a message like
`context deadline exceeded` / `RetriesExceeded`. Flux gives up retrying a
stuck HelmRelease and **won't self-heal it** — future value changes silently
stop applying until someone clears it. A `Stalled` HelmRelease can still have
a perfectly healthy `Running` pod, so don't stop at "the pod's fine."

## 2. Pods — status AND restarts

```bash
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -15
```

`Running` hides crash-looping — check restart counts separately. For anything
non-Running/Completed or high-restart: `kubectl describe pod` and `kubectl
logs --previous` before moving on.

## 3. Warning events — fastest way to surface active problems

```bash
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -30
```

One command tends to surface most of what matters: readiness-probe timeouts,
`FailedScheduling`, `FailedCreatingDns` (Cloudflare tunnel), Helm repo fetch
failures. Repeat counts (`x912 over 24h`) tell you how long something's been
broken, not just that it is right now.

## 4. Node conditions + host systemd

```bash
kubectl get nodes -o wide
kubectl describe node kube-vm | grep -A6 Conditions:
ssh kube-vm "systemctl --failed --no-legend; df -h /; ls /run/flannel/subnet.env"
```

`systemctl --failed` with no output is healthy. Empty/missing
`/run/flannel/subnet.env` after a reboot means pods will hang in
`ContainerCreating` — see the `nixos-deploy` skill. If `ssh kube-vm` doesn't
resolve in your shell, use `ssh root@192.168.200.2`.

## 5. NFS backend — check even if nothing points at it

NFS problems rarely announce themselves as NFS problems — they show up as
unrelated apps crash-looping or timing out. **The tell: load average wildly
higher than actual CPU/memory use**, because processes are stuck in D-state
waiting on NFS, not doing real work.

```bash
kubectl top node
ssh kube-vm "uptime; ps -eo stat,comm | grep '^D'"
ping -c2 nas.internal   # NFS server; see CLAUDE.md NAS section
```

If NFS is down, expect cascading readiness failures in step 3 across every
app on `vulcan-nfs`/`vulcan-nfs-strict` — that's one incident, not twenty
separate bugs. Fix the backend before restarting apps one by one. Current
backend: OMV VM (`192.168.1.117`) on amphoreus (`192.168.1.31`) — see
`docs/nfs-migration-omv.md`.

If the OMV VM itself is unreachable even though the network path is fine,
check Proxmox on amphoreus before assuming it's a guest OS problem:

```bash
ssh root@192.168.1.31 "qm status 100 --verbose | grep -E 'qmpstatus|^status'"
```

`qmpstatus: io-error` means QEMU paused the VM because a passthrough disk hit
an I/O error — check `dmesg -T | tail -60` and `lsusb -t` on amphoreus for a
dropped USB drive before resuming or rebooting the VM. amphoreus's storage
(`birdpool`) is three USB-attached disks; a hypervisor **reboot** power-cycles
the USB host controller and can recover a wedged drive that a software
unbind/bind (`echo <bus-port> > /sys/bus/usb/drivers/usb/unbind`, then
`bind`) can't — try the non-destructive unbind/bind first, escalate to a full
reboot if that doesn't bring the `by-id` path back. If neither works, the
drive/enclosure needs physical power-cycling.

## 6. Orphaned storage — stale node affinity

A PV pinned to a node that's since left the cluster schedules forever and
silently — `FailedScheduling` fires hundreds of times but nothing pages you.

```bash
kubectl get pv -o custom-columns='NAME:.metadata.name,AFFINITY:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values'
```

Any hostname other than the live node(s) (e.g. `gallifrey`, `vulcan`) is
orphaned storage from a decommissioned host. Fix is usually deleting and
recreating the PVC on the live node — confirm with the user before deleting
anything.

## 7. Certificates

```bash
kubectl get certificate -A | grep -v True
```

Empty output = all issued. Anything else risks an expired/broken TLS cert
soon — `kubectl describe certificate <name>` for the ACME/issuer error.

## 8. Web UIs — actually load them, don't infer from pod status

A `Ready` pod doesn't mean the app is reachable through Traefik/Cloudflare.
Hit every ingress hostname:

```bash
for h in $(kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' | sort -u); do
  code=$(curl -sk -o /dev/null -m5 -w '%{http_code}' "https://$h")
  echo "$code  $h"
done
```

Expect `200`, or `302`/`303` to `auth.wrenspace.dev` for Authelia-protected
apps — that redirect **is** healthy. Flag `000` (unreachable) or `5xx`.

## 9. Resource overview — disk, load, capacity headroom

Capture this even on a clean run — slow degradation (disk filling, memory
creeping toward limits) doesn't throw errors until it suddenly does.

```bash
ssh kube-vm "df -h /; free -h; uptime"
kubectl describe node kube-vm | grep -A8 "Allocated resources"
kubectl top pods -A --no-headers | sort -k3 -rh | head -10   # top CPU consumers
kubectl top pods -A --no-headers | sort -k4 -rh | head -10   # top memory consumers
```

To flag pods close to their *own* configured limit (not just top absolute
consumers), cross-reference usage against `resources.limits`:

```bash
kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.containers[].resources.limits.memory != null) |
  "\(.metadata.namespace)/\(.metadata.name)"' | sort > /tmp/limited-pods.txt
kubectl top pods -A --no-headers | awk '{print $1"/"$2, $3, $4}' | sort | \
  join - /tmp/limited-pods.txt
```

For anything in that joined list, `kubectl describe pod <name> -n <ns> | grep
-A4 Limits` to get the actual ceiling and compute %. Flag anything over
~80% of its memory limit — OOMKilled often shows up as a restart count that
already moved, not a live warning.

## Anything else worth a glance

- SealedSecrets sync: `kubectl get sealedsecret -A -o custom-columns=NAME:.metadata.name,SYNCED:.status.conditions[0].status | grep -v True` — should all be `True`
- MetalLB pool exhaustion: `kubectl get svc -A | grep LoadBalancer` — any `<pending>` external IP means the pool's out of addresses
- etcd snapshot cadence (single-node cluster, no HA — backups matter more): `ssh kube-vm "sudo k3s etcd-snapshot list"`

## Report Format

Every run ends with two parts, in this order:

**1. Stats overview** — always shown, even when nothing is broken:

| Metric | Value |
|---|---|
| Node disk usage | e.g. `34% /` |
| Load average (1m/5m/15m) | e.g. `0.42, 0.51, 0.60` |
| Memory: allocated (requests) vs. actual usage | e.g. `90% requests / 62% actual` |
| Pods over ~80% of their memory limit | list, or `none` |
| Flux Kustomizations/HelmReleases | `N ready / N total` |
| Pods not Running/Completed | `N` (list namespaces/names if any) |
| Web UIs failing (000/5xx) | `N / total` (list hostnames if any) |

**2. Anomalies + remediation choices** — for each anomaly with a plausible
fix, don't act unilaterally: present it via the `AskUserQuestion` tool as a
multiple-choice decision (e.g. "reconcile now" / "investigate further" /
"leave for later", plus app-specific options where relevant — like "delete
and recreate the PVC" for an orphaned volume). Batch unrelated anomalies into
separate questions so the user can decide each independently rather than
picking one blanket action. Purely informational findings (e.g. a stale
decaying load-average metric that's already recovering) belong in the stats
overview or a one-line note, not a question.

## Common mistakes

- **Stopping at `kubectl get pods -A`** — misses stuck Helm releases, orphaned
  PVs, NFS-cascade failures, and cert issues entirely.
- **Treating each crash-looping app as a separate bug** — check step 5 (NFS)
  and step 3 (events) first; one backend outage commonly presents as a dozen
  unrelated-looking app failures.
- **Assuming a 302 on a web UI check means it's down** — Authelia's
  forward-auth redirect is the expected healthy response for protected apps.
- **Resuming or rebooting a paused VM without checking the storage layer
  first** — `qmpstatus: io-error` means a passthrough disk failed; fix that
  (or confirm the pool tolerates the loss) before touching the VM, or you'll
  hit the same error again.
- **Applying a fix instead of asking** — this skill is diagnostic. Surface
  anomalies as `AskUserQuestion` choices (see Report Format) instead of
  reconciling a HelmRelease, deleting a PVC, or restarting a service on your
  own initiative.

See also: `nixos-deploy` for the flannel `subnet.env` boot quirk in more
depth; `docs/nfs-migration-omv.md` for the NFS backend's current topology.
