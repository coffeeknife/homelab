# Etheirys → 7050 cutover runbook

Executable runbook for migrating **all of etheirys's guests** onto the new
**OptiPlex 7050 Micro** and retiring the iMac. This supersedes the rough
"Cutover checklist" in [`etheirys-retirement.md`](etheirys-retirement.md)
(which holds the *why* / hardware rationale); this doc is the *how*.

## The governing constraint: no overlap window

The iMac is opened up to **harvest its 2×16GB RAM into the 7050 before the 7050
can boot** with enough memory. So etheirys and the 7050 are **never on at the
same time** — there is no live side-by-side migration. The whole homelab
(k3s cluster + all LXCs) goes fully **dark** during the physical swap.

**Strategy to make that safe:** amphoreus/OMV (`192.168.1.117`, the NAS) stays
up the entire time. We push **all guest data to OMV as `vzdump` backups while
etheirys is still running** (zero-downtime, snapshot mode). The dark window then
only costs the physical swap + Proxmox rebuild + restore — **no data is in
flight during it, and nothing is lost if the rebuild runs long.** etheirys's SSD
is also left intact as a second fallback until the 7050 is proven.

## Verified pre-flight facts (checked 2026-07-13)

- **Backup target is a one-line fix.** OMV `.117` already exports
  `/mnt/birdpool/pvebackup` (5.8T, 2.9T free, existing `dump/` dir). etheirys's
  `nfs-backup` storage points at the dead vulcan `.69`; just change the server.
- **All guest disks live on `local-lvm`** (etheirys's 954G SATA SSD) — nothing to
  untangle from NFS. The `nfs`/`nfs-backup` PVE storages hold no guest disks.
- **kube-vm's 300G disk is mostly air:** 95G used, of which only **~19G is
  irreplaceable** (local-path PVs: Prometheus, Loki, MariaDB, Immich pg). 48G is
  reconstructible containerd image layers; the rest is OS/swap/logs. After
  `fstrim` the real footprint is **~50G**.

### Guests to migrate

| Guest | ID | Bridge / VLAN | IP | Real size | Restore order |
|-------|-----|--------------|-----|-----------|---------------|
| gitea | 124 | vmbr4 / VLAN 4 | .200.52 (DHCP) | ~4G | **1st** (Flux source) |
| mqtt | 101 | vmbr3 / VLAN 3 | .100.3 (static) | ~2G | 2nd |
| vaultwarden | 113 | vmbr3 / VLAN 3 | .100.6 (DHCP) | ~1G | 3rd |
| hass | 100 | vmbr2 / untagged | .1.123 (DHCP) | ~10G | 4th |
| kube-vm | 202 | vmbr4 / VLAN 4 | .200.2 (live node IP) | ~50G | 5th |

DHCP guests keep their IPs because `vzdump` preserves each guest's MAC, so the
router's reservations still match.

### Networking to reproduce on the 7050

etheirys runs three bridges over one NIC (`enp3s0f0`). The 7050's onboard NIC
has a **different name** (likely `eno1`), so `/etc/network/interfaces` is
rewritten with the new NIC name but the **same bridge/VLAN structure**:

| Bridge | VLAN | Subnet | Purpose |
|--------|------|--------|---------|
| vmbr2 | untagged | 192.168.1.0/24 | Home network (host IP `.53`) |
| vmbr3 | VLAN 3 (`<nic>.3`) | 192.168.100.0/24 | Isolated / IoT services |
| vmbr4 | VLAN 4 (`<nic>.4`) | 192.168.200.0/24 | k3s cluster network |

**The 7050 must plug into a trunk switch port carrying VLANs 3 & 4 tagged** (plus
native/untagged for vmbr2) — the same port profile etheirys uses today.

---

## Phase 0 — Prep (etheirys UP, zero downtime)

1. **Repoint the backup storage.** Edit `/etc/pve/storage.cfg` on etheirys, in
   the `nfs-backup` block change `server 192.168.1.69` → `server 192.168.1.117`
   (leave `export /mnt/birdpool/pvebackup`). Confirm it comes online:
   ```bash
   pvesm status | grep nfs-backup   # expect: active
   ```
2. **Shrink kube-vm's live footprint** (reduces backup size):
   ```bash
   ssh robin@192.168.200.2 'sudo fstrim -av'
   # optional: prune reclaimable container images
   ssh robin@192.168.200.2 'sudo k3s crictl rmi --prune'
   ```
3. **Snapshot-mode backup of every guest to OMV** (guests keep running):
   ```bash
   for id in 124 101 113 100 202; do \
     vzdump $id --mode snapshot --storage nfs-backup --compress zstd; done
   ```
4. **HARD GATE — verify the backups exist and are readable on OMV** before
   touching hardware:
   ```bash
   pvesm list nfs-backup | grep -E 'vzdump-(qemu|lxc)-(124|101|113|100|202)'
   ```
   Do **not** proceed past this line until all five appear.

## Phase 1 — Cutover (downtime begins)

5. **Stop guests and take a final stop-mode backup** of the stateful ones so the
   last-moment DB / git / HA state is captured (snapshot backups from Phase 0 are
   crash-consistent, but a clean stop-mode dump avoids any drift):
   ```bash
   qm stop 202; for id in 124 113 100; do pct stop $id; done; pct stop 101
   for id in 124 113 100 202; do \
     vzdump $id --mode stop --storage nfs-backup --compress zstd; done
   ```
   Re-verify with the Phase 0 step-4 command.
6. **Power off etheirys.** Its SSD still holds the originals — untouched fallback.

## Phase 2 — Harvest & assemble

7. Pull the **2×16GB DDR4-2400 SO-DIMMs** (+ PSU + i5-7400 CPU per the retirement
   doc). Install the RAM in the 7050; rack it into the **same trunk switch port**.

## Phase 3 — Rebuild the host

8. Install **Proxmox VE** on the 7050 (default single-disk layout →
   `local` + `local-lvm` thin, same as etheirys). Set hostname/IP to
   etheirys's (`192.168.1.53`, `vmbr2`).
9. **Recreate the bridges** in `/etc/network/interfaces` using the new NIC name
   and the VLAN table above (vmbr2 untagged, vmbr3 `<nic>.3`, vmbr4 `<nic>.4`).
10. **Add the OMV backup storage** so restores can read it (identical block):
    ```
    nfs: nfs-backup
        export /mnt/birdpool/pvebackup
        path /mnt/pve/nfs-backup
        server 192.168.1.117
        content backup
    ```

## Phase 4 — Restore

11. **Restore in dependency order — gitea first** (Flux source), then the rest:
    ```bash
    pct restore 124 <gitea-backup>   --storage local-lvm   # then verify Flux
    pct restore 101 <mqtt-backup>    --storage local-lvm
    pct restore 113 <vw-backup>      --storage local-lvm
    pct restore 100 <hass-backup>    --storage local-lvm
    qmrestore <kube-vm-backup> 202   --storage local-lvm
    ```
    kube-vm's disk restores as a **300G thin volume** on the (smaller) 256G+
    physical disk. Proxmox permits this — `qmrestore` does a **sparse** restore
    (~50G real), may warn, won't hard-fail. *(Watch thin-pool fill afterward.)*
12. **Before booting kube-vm, drop the dead AMD passthrough line:**
    ```bash
    qm set 202 --delete hostpci0     # AMD RX560 is gone
    qm start 202
    ```

## Phase 5 — Verify

13. `ssh robin@192.168.200.2 'ls /run/flannel/subnet.env'` — the NixOS boot
    quirk; if missing, `sudo systemctl restart k3s`.
14. `flux get kustomizations -A` and `flux reconcile kustomization flux-system`
    — confirm the GitOps loop is live from restored gitea.
15. Pods healthy (`kubectl get pods -A`), then spot-check the LXC services:
    Home Assistant (`.1.123`, Thread/OTBR), mqtt broker, Vaultwarden
    (`vault.wrenspace.dev`), TLS/ingress.

---

## Deferred (intentionally not in the cutover window)

- **Shrink kube-vm's disk to 128G.** Its *purpose* (fit the smaller disk) is
  already met by thin provisioning. A true block-device shrink needs an offline
  root-fs resize (rescue ISO → `resize2fs` → shrink partition → `lvreduce`) — do
  it later as its own low-stakes maintenance window, or skip it and just monitor
  thin-pool usage.
- **Jellyfin HW transcode on Intel HD630.** kube-vm is already `machine: q35`, so
  the iGPU can be added later with `qm set 202 -hostpci0 <id>,pcie=1` on a stopped
  VM — **no VM recreation** (that pain was the one-time i440fx→q35 switch, already
  done). Passing the host's *only* iGPU has its own quirks (i915 blacklist / vfio
  bind, host goes headless); Jellyfin runs on software transcode until then.

## Rollback

If the 7050 rebuild fails: etheirys's SSD is untouched. Reinstall the RAM in the
iMac (or source temporary sticks), power it back on, and the original guests boot
as-is. Nothing was deleted from etheirys — only copied.
