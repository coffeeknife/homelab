#!/usr/bin/env bash
#
# One-time migration: align qbittorrent's download tree with PUID/PGID 1000.
#
# WHY
#   qbittorrent ran as PUID/PGID 0 with an unset UMASK, so it created release
#   directories as root:root 0755 on the shared NFS export
#   (/mnt/birdpool/jellyfin/media, mounted at /data by both qbit and the arr
#   apps). The arr apps run as uid 1000, so they could copy a file into the
#   library but could not unlink the source afterwards -- deleting a file needs
#   write permission on its *containing* directory. Every import failed and
#   retried forever, re-copying multi-GB files onto the SMR-backed media
#   dataset.
#
#   values.qbit.yaml now sets PUID/PGID 1000 + UMASK 002 so NEW directories are
#   created correctly. This script fixes the ~99 pre-existing entries, which do
#   not self-heal. (qbit's /config PVC DOES self-heal -- the LinuxServer image
#   chowns it on startup -- so it is deliberately not touched here.)
#
# ORDER MATTERS
#   qbit is scaled to 0 first. If it kept running as root during the chown, new
#   writes would land as root:root again and re-create the problem. If instead
#   the new uid-1000 pod started before the chown, it would lose write access to
#   its own in-progress files and mark torrents errored.
#
# SCOPE
#   ONLY .../media/downloads. The library dirs (/data/tv, /data/movies, ...) are
#   already 0777 and import into them works fine -- recursing over the whole
#   ~10TB pool would take hours and gains nothing.
#
# Requires: the values.qbit.yaml change committed and pushed first (step 0).

set -euo pipefail

OMV_HOST="robin@192.168.1.117"
DOWNLOADS="/mnt/birdpool/jellyfin/media/downloads"
NS="arr-stack"
DEPLOY="qbittorrent-vpn"

echo "==> 0. Confirming the new PUID reached the cluster"
# kubectl renders the ConfigMap's values file as a literal block, so the YAML is
# greppable. Key off PUID specifically -- a bare "1000" could match elsewhere.
if ! kubectl get cm -n "$NS" qbittorrent-values -o yaml \
     | grep -A1 'name: PUID' | grep -q 'value: "1000"'; then
  echo "    ERROR: qbittorrent-values ConfigMap does not carry PUID 1000 yet."
  echo "    Commit + push apps/media/arr/manifests/values.qbit.yaml, then:"
  echo "      flux reconcile kustomization arr-stack -n flux-system"
  exit 1
fi
echo "    ok"

echo "==> 1. Scaling $DEPLOY to 0 (pauses 25 torrents; they resume in step 4)"
kubectl scale deploy -n "$NS" "$DEPLOY" --replicas=0
kubectl wait --for=delete pod -n "$NS" -l app.kubernetes.io/name=qbittorrent-vpn --timeout=120s 2>/dev/null || true
echo "    stopped"

echo "==> 2. Ownership BEFORE (server side)"
ssh "$OMV_HOST" "find '$DOWNLOADS' -maxdepth 2 -printf '%u:%g\n' | sort | uniq -c | sort -rn"

echo "==> 3. chown + chmod (needs your sudo password on OMV)"
# -R over downloads only. u+rwX,g+rwX adds read/write for owner+group and the
# execute/search bit on directories only (capital X). Nothing is removed.
ssh -t "$OMV_HOST" "sudo chown -R 1000:1000 '$DOWNLOADS' && sudo chmod -R u+rwX,g+rwX '$DOWNLOADS'"

echo "==> 3b. Ownership AFTER"
ssh "$OMV_HOST" "find '$DOWNLOADS' -maxdepth 2 -printf '%u:%g\n' | sort | uniq -c | sort -rn"

echo "==> 4. Reconciling the HelmRelease to bring qbit back as uid 1000"
# NOT `kubectl scale --replicas=1`. The ConfigMap carrying the new PUID lands as
# soon as the arr-stack Kustomization applies, but the Deployment spec only
# picks it up when the HelmRelease re-renders -- so a plain scale-up would
# restart the pod with the OLD PUID 0 and immediately re-create root-owned
# directories, undoing the chown above. Reconciling the HelmRelease re-renders
# the Deployment (new env) and restores replicas to 1 in one step.
flux reconcile helmrelease qbittorrent -n "$NS" --force
kubectl rollout status deploy -n "$NS" "$DEPLOY" --timeout=300s

echo "==> 5. Verifying qbittorrent now runs as uid 1000"
POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=qbittorrent-vpn -o name | head -1)
kubectl exec -n "$NS" "${POD#pod/}" -c qbittorrent -- sh -c 'echo "  qbit process: $(ps -eo user,uid,comm | grep -i qbittorrent | head -1)"; touch /data/downloads/.uid-check && ls -ln /data/downloads/.uid-check && rm -f /data/downloads/.uid-check'

cat <<'EOF'

==> Done. What to watch next:

  # the import failures should stop appearing
  kubectl logs -n arr-stack -l app.kubernetes.io/name=sonarr --tail=200 \
    | grep -c "Couldn't import"

  # sonarr's restart count should stop climbing (was 1083)
  kubectl get pod -n arr-stack -l app.kubernetes.io/name=sonarr \
    -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount

  # in the qbit WebUI, any torrent that errored on the old permissions needs a
  # force-recheck to pick the files back up.

If the liveness-probe failures do NOT subside within a day of imports clearing,
the SMR media dataset is the next suspect -- it still measures ~300ms/fsync vs
0.041s on birdpool/k8s-nfs, which got sync=disabled on 2026-07-30.
EOF
