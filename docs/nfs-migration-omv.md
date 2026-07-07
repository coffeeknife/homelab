# NFS backend migration: vulcan → amphoreus/OMV

The `birdpool` ZFS pool moved from **vulcan** (`192.168.1.69`, kernel NFS exports)
to an **OpenMediaVault** VM on **amphoreus** (`192.168.1.117`). OMV does **not**
export shares automatically — each NFS share must be created in the OMV web UI
before the cluster can mount it. This is a **staged, per-volume** migration: bring
up one OMV share, flip that volume's manifest, reconcile, verify, then move on.

## Per-volume procedure

For each share below:

1. **OMV UI** → *Storage ▸ Shared Folders* → ensure a shared folder maps to the
   birdpool path. → *Services ▸ NFS ▸ Shares* → add the export (client
   `192.168.200.0/24`, read/write, `subtree_check` off, `insecure` if needed for
   the k3s nodes). Apply the pending config.
2. **Confirm the export path OMV presents.** From a cluster node:
   `showmount -e 192.168.1.117`. If OMV exports at the real path
   (`/mnt/birdpool/...`), only `server:` changes in the manifest. If OMV exports
   under a different root (e.g. `/export/<share>`), rewrite **both** `server:` and
   `path:`.
3. **Edit the manifest(s)**: set `server: 192.168.1.117` (and `path:` if it moved).
4. **Reconcile**: `git commit` + push, then `flux reconcile kustomization <app> -n flux-system`.
5. **Verify**: pod mounts and reads data — `kubectl -n <ns> exec <pod> -- ls <mountpath>`.

> Line numbers below are a snapshot; re-grep before editing:
> `grep -rn "192.168.1.69" apps/`

---

### 1. Dynamic provisioner — `/mnt/birdpool/k8s-nfs`

Backs the `vulcan-nfs` (default) and `vulcan-nfs-strict` StorageClasses. **Do this
one first** — the most PVCs depend on it.

- `apps/infrastructure/nfs-provisioner/manifests/values.yaml` — `server:` (line ~2), `path:` (line ~3, `/mnt/birdpool/k8s-nfs`)
- Reconcile: `flux reconcile kustomization nfs-provisioner -n flux-system`
- Note: the two StorageClasses (`storageclasses.yaml`) carry `pathPattern` only, no
  server IP — nothing to change there. Names stay `vulcan-nfs*` (do **not** rename).

### 2. Media library — `/mnt/birdpool/jellyfin/media`

Shared by jellyfin, the arr suite, qbittorrent, and unpackerr. One OMV share
covers all of these.

- `apps/media/jellyfin/manifests/values.yaml` — `server:` (line ~9)
- `apps/media/arr/manifests/values.arr.yaml` — `server:` at ~57, 112, 206, 262, 314, 361 (6 mounts)
- `apps/media/arr/manifests/values.qbit.yaml` — `server:` (line ~19)
- `apps/media/arr/manifests/unpackerr.yaml` — `server:` (line ~54)
- Reconcile: `flux reconcile kustomization jellyfin -n flux-system` and `... arr ...`

### 3. Lidatube iTunes subpath — `/mnt/birdpool/jellyfin/media/itunes`

- `apps/media/arr/manifests/lidatube.yaml` — `server:` (line ~73), `path:` (line ~74)
- This is a **subdirectory of share #2**. With NFSv4 you can usually mount a subpath
  of an existing export without a separate OMV share — verify with
  `mount -t nfs4 192.168.1.117:/mnt/birdpool/jellyfin/media/itunes /mnt/test`. If OMV
  refuses it, add a dedicated NFS share for the itunes path.

### 4. Kavita — `/mnt/birdpool/kavita/data`

- `apps/media/kavita/manifests/nfs-vol.yaml` — `path:` (line ~17), `server:` (line ~18)

### 5. Immich — `/mnt/birdpool/photo`

- `apps/services/immich/manifests/nfs-vol.yaml` — `path:` (line ~15), `server:` (line ~16)

### 6. Nextcloud — `/mnt/birdpool/drive`

- `apps/services/nextcloud/manifests/nfs-volume.yaml` — `path:` (line ~30), `server:` (line ~31)

### 7. Paperless — `/mnt/birdpool/filing`

- `apps/services/paperless-ngx/manifests/nfs-volume.yaml` — `path:` (line ~15), `server:` (line ~16)

---

## Progress

- [ ] 1. Provisioner `/mnt/birdpool/k8s-nfs`
- [ ] 2. Media `/mnt/birdpool/jellyfin/media`
- [ ] 3. Lidatube `/mnt/birdpool/jellyfin/media/itunes`
- [ ] 4. Kavita `/mnt/birdpool/kavita/data`
- [ ] 5. Immich `/mnt/birdpool/photo`
- [ ] 6. Nextcloud `/mnt/birdpool/drive`
- [ ] 7. Paperless `/mnt/birdpool/filing`

## Not part of this migration (already handled)

- **Cockpit** (`apps/external-ingress/manifests/cockpit.yaml`) — pointed at vulcan's
  host UI; **removed**.
- **Loki / Garage S3** (`apps/monitoring/loki/manifests/values.yaml`) — chunk store
  was Garage on vulcan; Loki + promtail **disabled** pending a new object store.
