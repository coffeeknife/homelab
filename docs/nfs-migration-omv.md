# NFS backend migration: vulcan → amphoreus/OMV

The `birdpool` ZFS pool moved from **vulcan** (`192.168.1.69`, kernel NFS exports)
to an **OpenMediaVault** VM on **amphoreus** (`192.168.1.117`). vulcan's NFS is
retired (host down). This migration also **decouples the cluster from the NFS
IP**: instead of hardcoding `192.168.1.117`, all NFS volumes now use the stable
host alias **`nas.internal`**.

## How the decoupling works (read first)

`nas.internal` is mapped to the backend IP in **`nixos/modules/common.nix`**:

```nix
networking.hosts = { "192.168.1.117" = [ "nas.internal" ]; };
```

NFS is mounted by the **kubelet at the host level** (outside cluster DNS), so the
name must resolve via the node's host resolver — `/etc/hosts` does that on every
node. **Moving the backend again later = change that one line + `colmena apply`;**
no PV or manifest churn.

Deploy the hosts entry to every schedulable node before cutting volumes over:

```bash
cd nixos && ~/.nix-profile/bin/colmena apply --on kube-vm switch
# gallifrey: BLOCKED — see "gallifrey" note at the bottom.
```

## The immutable-PV catch (why this is per-volume surgery)

A bound PV's `spec.nfs.server` is **immutable**. Editing the provisioner value or a
static PV manifest only affects *newly* created PVs — the existing bound PVs keep
their old `192.168.1.69`. Every existing PV is `Retain`, so the backing dir is safe
to recreate. To re-point one:

1. `kubectl get pv <pv> -o yaml > /tmp/pv.yaml`
2. Edit `spec.nfs.server` → `nas.internal`; strip `status`, `metadata.uid`,
   `resourceVersion`, `creationTimestamp`, `finalizers`; **keep `spec.claimRef`**
   (name+namespace+uid) so the PVC re-binds.
3. Scale the workload down (or delete the stuck pod `--force`), delete the PV
   (`Retain` keeps the data), `kubectl apply -f /tmp/pv.yaml`, scale back up.

For **Helm-managed** PV/PVC (the provisioner) or **Flux-kustomize-managed** static
PVs, the tool can't update the immutable field either — delete the old PV/PVC so
the owner recreates it fresh from the (now `nas.internal`) manifest.

## OMV export facts (confirmed 2026-07-08)

- OMV exports at the **real paths** (`/mnt/birdpool/...`) — no `/export` rewrite, so
  only `server:` changes in manifests, never `path:`.
- `nfsvers=4.1`, so subpaths of an export mount fine without a separate share.
- Only `/mnt/birdpool/k8s-nfs` and `/mnt/birdpool/immich` are scoped to
  `192.168.200.0/24`; the rest are exported `*` (still mountable from the cluster).
- Probe from a node: `ssh root@192.168.200.2 'showmount -e 192.168.1.117'`.

## Volumes

### 1. Dynamic provisioner — `/mnt/birdpool/k8s-nfs`  ✅ DONE (2026-07-08)

- `apps/infrastructure/nfs-provisioner/manifests/values.yaml` — `server: nas.internal`
  + `nodeSelector: kubernetes.io/hostname: kube-vm` (pinned because gallifrey can't
  get the hosts entry yet — see bottom).
- Old Helm-managed PV/PVC deleted; Helm recreated them at `nas.internal`. Provisioner
  Running on kube-vm, HelmRelease Ready (v3).
- Note: the ~23 **existing dynamic `k8s-nfs` PVs** (`pvc-…`) still hardcode
  `192.168.1.69` and must each be recreated (see immutable-PV catch). Not yet done.

### 2. Media library — `/mnt/birdpool/jellyfin/media`

Inline NFS volumes (kubelet resolves the hostname the same way). Shared by jellyfin,
arr suite, qbittorrent, unpackerr. Set `server: nas.internal`:
- `apps/media/jellyfin/manifests/values.yaml`, `apps/media/arr/manifests/values.arr.yaml`
  (6 mounts), `values.qbit.yaml`, `unpackerr.yaml`.

### 3. Lidatube iTunes subpath — `/mnt/birdpool/jellyfin/media/itunes`
- `apps/media/arr/manifests/lidatube.yaml` — `server: nas.internal`. Subpath of #2.

### 4. Kavita — `/mnt/birdpool/kavita/data` — `apps/media/kavita/manifests/nfs-vol.yaml`
### 5. Immich — `/mnt/birdpool/photo` — `apps/services/immich/manifests/nfs-vol.yaml`
### 6. Nextcloud — `/mnt/birdpool/drive` — `apps/services/nextcloud/manifests/nfs-volume.yaml`
### 7. Paperless — `/mnt/birdpool/filing` — `apps/services/paperless-ngx/manifests/nfs-volume.yaml`

For #4–#7: edit `server:` → `nas.internal` in the manifest AND recreate the existing
static PV (immich-pv/kavita-pv/nextcloud-pv/paperless-pv) per the immutable-PV catch.

## Progress — COMPLETE (2026-07-08)

- [x] 1. Provisioner `/mnt/birdpool/k8s-nfs` (values + provisioner root PV, pinned to kube-vm)
- [x] 1b. Recreated all 22 existing dynamic `k8s-nfs` PVs at `nas.internal`
- [x] 2. Media `/mnt/birdpool/jellyfin/media` (jellyfin + arr inline volumes)
- [x] 3. Lidatube `/mnt/birdpool/jellyfin/media/itunes`
- [x] 4. Kavita  [x] 5. Immich  [x] 6. Nextcloud  [x] 7. Paperless (static PVs recreated)

Verified: all 27 NFS PVs report `server: nas.internal` and `Bound`; 0 FailedMount
events referencing `192.168.1.69`; no not-Ready pods cluster-wide. All previously
broken apps (arr suite, jellyfin, nextcloud, authelia, home-assistant, paperless,
kavita, grafana, notify, protonmail) recovered. (immich is intentionally scaled to 0.)

### Follow-ups
- **gallifrey is cordoned** (`kubectl uncordon gallifrey` after it gets `nas.internal`).
  Its bootloader still needs the declarative revert (see below); until then NFS pods
  must stay on kube-vm.
- Once gallifrey resolves `nas.internal`, the `nodeSelector` pin on the provisioner
  (`apps/infrastructure/nfs-provisioner/manifests/values.yaml`) can be removed.

## gallifrey (blocker)

gallifrey is a schedulable k3s worker but its `nas.internal` hosts entry can't be
deployed: its 30MB FAT boot partition can't hold the Pi kernel under the current
`boot.loader.raspberry-pi.bootloader = "kernel"` mode, so `colmena apply` fails and
the last attempt left its boot config broken. **Do not reboot gallifrey** until its
bootloader is reverted to `generic-extlinux-compatible` (kernel on ext4). Until then,
NFS-mounting workloads are pinned to kube-vm.

## Not part of this migration (already handled)

- **Cockpit** — removed. **Loki/Garage S3** — disabled pending a new object store.
