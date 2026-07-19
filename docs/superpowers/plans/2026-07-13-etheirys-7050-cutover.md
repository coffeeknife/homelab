# Etheirys → 7050 Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This is a hardware cutover, not a code change.** "Tests" are verification commands with expected output. Some tasks are **physical/manual** (marked 🔧 — RAM harvest, Proxmox install) and cannot be run by an agent; the operator does them and reports back. There are no `git commit` steps — the checkpoints are **backup-verification gates**.

**Goal:** Migrate all five etheirys guests onto the new OptiPlex 7050 Micro and retire the iMac, with zero data loss despite a no-overlap (both-machines-never-on) window.

**Architecture:** Front-load every guest as a `vzdump` backup to OMV (`192.168.1.117`) while etheirys still runs, power off etheirys, harvest its RAM into the 7050, rebuild Proxmox on the 7050, and restore all guests from OMV — gitea (Flux source) first, kube-vm last. Disk shrink and GPU passthrough are deferred out of the downtime window.

**Tech Stack:** Proxmox VE (`vzdump`/`qmrestore`/`pct restore`), LVM-thin, NFS (OMV/birdpool), k3s on NixOS, Flux CD.

> **STATUS — ✅ COMPLETE 2026-07-18. Cutover done, cluster verified healthy.**
> The 7050 = **tau-ceti** at **192.168.1.119** (kept `.119`, not `.53`). All five
> guests restored, auto-started (`onboot`+order), node Ready, Flux reconciling
> from restored gitea, LXC services confirmed. etheirys off/retired (SSD fallback
> intact). Real-world deltas + the kube-vm disk/`efidisk0` gotchas are documented
> in the runbook banner (`docs/etheirys-7050-cutover.md`) and CLAUDE.md.
>
> _History:_
> - **Phase 0 (2026-07-13):** Tasks 1–3 done, zero downtime — `nfs-backup`
>   repointed `.69`→`.117`; kube-vm `fstrim` reclaimed 9.1 GiB; 5 snapshot
>   archives verified on OMV.
> - **Cutover day (2026-07-18):** resumed at Task 4. tau-ceti was pre-installed on
>   temp 16GB, so guests were restored *while it ran* and left stopped+`onboot`;
>   dark window = RAM swap + auto-boot only. kube-vm restore hit 99.89% thin pool
>   (disk is ~117G real) → fixed via `lvextend +100%FREE` + `virt-sparsify
>   --in-place` → 81%.

## Global Constraints

- **No overlap:** etheirys and the 7050 are NEVER powered on at the same time.
- **HARD GATE:** never power off etheirys until all five backups are verified readable on OMV (Task 3 + Task 4).
- **Fallbacks:** OMV backups + etheirys's untouched SSD are two independent recovery paths. Do not wipe etheirys's SSD until the 7050 is fully proven (Task 13–14 green).
- **Host identity:** the 7050 takes etheirys's identity exactly — hostname context, IP `192.168.1.53`, bridges vmbr2 (untagged/home), vmbr3 (VLAN 3/IoT), vmbr4 (VLAN 4/cluster).
- **Restore order is dependency order:** gitea (124) → mqtt (101) → vaultwarden (113) → hass (100) → kube-vm (202).
- **Reference runbook:** `docs/etheirys-7050-cutover.md` (the prose companion to this plan).

---

## Task 1: Repoint the backup storage to OMV

**Files:**
- Modify: `/etc/pve/storage.cfg` on etheirys (`root@192.168.1.53`), `nfs-backup` block

**Interfaces:**
- Produces: an `active` PVE storage named `nfs-backup` backed by `192.168.1.117:/mnt/birdpool/pvebackup`, used by every backup/restore task below.

- [ ] **Step 1: Inspect the current (broken) storage block**

Run: `ssh root@192.168.1.53 'grep -A5 "nfs-backup" /etc/pve/storage.cfg'`
Expected: shows `server 192.168.1.69` (the dead vulcan address).

- [ ] **Step 2: Repoint the server to OMV**

Run:
```bash
ssh root@192.168.1.53 "sed -i '/^nfs: nfs-backup/,/^$/ s/server 192.168.1.69/server 192.168.1.117/' /etc/pve/storage.cfg"
```

- [ ] **Step 3: Verify the storage comes online**

Run: `ssh root@192.168.1.53 'pvesm status | grep nfs-backup'`
Expected: status `active` with non-zero Total/Available (~2.9T free).

---

## Task 2: Shrink kube-vm's live footprint

**Files:** none (runtime state on kube-vm, `robin@192.168.200.2`)

**Interfaces:**
- Produces: kube-vm root fs with unused blocks trimmed, so its Task 3 backup is ~50G not ~95G.

- [ ] **Step 1: Trim unused blocks**

Run: `ssh robin@192.168.200.2 'sudo fstrim -av'`
Expected: prints trimmed byte counts for `/` (e.g. `/: N GiB (… bytes) trimmed`).

- [ ] **Step 2: (Optional) prune reclaimable container images**

Run: `ssh robin@192.168.200.2 'sudo k3s crictl rmi --prune'`
Expected: lists removed image digests (or "no unused images"). Skip if unsure — it only affects backup size, and images re-pull anyway.

- [ ] **Step 3: Confirm real usage dropped**

Run: `ssh robin@192.168.200.2 'df -h / | tail -1'`
Expected: `Used` ≤ ~95G (lower after prune). This is the amount `vzdump` will actually copy.

---

## Task 3: Front-load all guest backups to OMV (zero downtime)

**Files:** none (snapshot backups written to `nfs-backup`)

**Interfaces:**
- Consumes: `nfs-backup` storage from Task 1.
- Produces: five `vzdump` archives on OMV (qemu-202, lxc-124/101/113/100), consumed by the restore tasks.

- [ ] **Step 1: Snapshot-mode backup of every guest (guests keep running)**

Run:
```bash
ssh root@192.168.1.53 'for id in 124 101 113 100 202; do \
  vzdump $id --mode snapshot --storage nfs-backup --compress zstd; done'
```
Expected: each guest ends with `INFO: Finished Backup of VM/CT <id>` and `backup finished successfully`. No `ERROR:` lines.

- [ ] **Step 2: HARD GATE — verify all five archives are present and readable**

Run:
```bash
ssh root@192.168.1.53 'pvesm list nfs-backup --content backup | \
  grep -Eo "vzdump-(qemu|lxc)-(124|101|113|100|202)[^ ]*" | sort'
```
Expected: exactly five distinct archives, one per guest ID (124, 101, 113, 100, 202).
**Do not proceed to Task 4 until all five appear.**

---

## Task 4: Final stop-mode backup + begin downtime

**Files:** none

**Interfaces:**
- Consumes: `nfs-backup`.
- Produces: crash-free stop-mode archives for the four stateful guests, capturing last-moment DB/git/HA state; leaves all guests stopped.

- [ ] **Step 1: Stop every guest**

Run: `ssh root@192.168.1.53 'qm stop 202; for id in 124 113 100 101; do pct stop $id; done'`
Expected: returns to prompt. Verify: `ssh root@192.168.1.53 'qm status 202; pct list'` shows kube-vm `stopped` and all CTs `stopped`.

- [ ] **Step 2: Final stop-mode backup of the stateful guests**

Run:
```bash
ssh root@192.168.1.53 'for id in 124 113 100 202; do \
  vzdump $id --mode stop --storage nfs-backup --compress zstd; done'
```
Expected: `backup finished successfully` for each. (mqtt/101 needs no final dump — its state is static config; the Task 3 snapshot suffices.)

- [ ] **Step 3: HARD GATE — re-verify the newest archive per stateful guest**

Run:
```bash
ssh root@192.168.1.53 'for id in 124 113 100 202; do \
  echo -n "CT/VM $id: "; pvesm list nfs-backup --content backup | \
  grep -Eo "vzdump-(qemu|lxc)-$id-[0-9_]+[^ ]*" | sort | tail -1; done'
```
Expected: a fresh (today-dated) archive line for each of 124, 113, 100, 202.
**This is the last safety check before hardware. Do not power off until it passes.**

---

## Task 5: 🔧 Power off etheirys (manual)

**Interfaces:**
- Consumes: verified backups (Task 3 + Task 4).
- Produces: etheirys powered down, SSD intact as fallback.

- [ ] **Step 1: Graceful shutdown**

Run: `ssh root@192.168.1.53 'shutdown -h now'`
Expected: SSH connection drops. Confirm it's fully off: `ping -c3 192.168.1.53` → 100% packet loss.

- [ ] **Step 2: Physically confirm power-off** before opening the chassis (no fans, no LED).

---

## Task 6: 🔧 Harvest RAM and assemble the 7050 (manual, physical)

**Interfaces:**
- Produces: 7050 with 2×16GB installed, cabled into the correct trunk switch port, powered on.

- [ ] **Step 1:** Open the iMac; remove the **2×16GB DDR4-2400 SO-DIMMs** (also pull the PSU and i5-7400 CPU per `docs/etheirys-retirement.md` — those are for resale, not the cutover).
- [ ] **Step 2:** Install both SO-DIMMs in the 7050.
- [ ] **Step 3:** Cable the 7050 into a **VLAN-trunk switch port** carrying VLANs 3 & 4 tagged + native/untagged (reuse etheirys's exact port if possible).
- [ ] **Step 4:** Power on. Enter BIOS once; confirm **32GB** detected and **VT-d / IOMMU enabled** (needed later for GPU passthrough).

---

## Task 7: 🔧 Install Proxmox VE and set host identity (manual)

**Files:**
- Create: fresh Proxmox install on the 7050's internal disk (default layout → `local` + `local-lvm` thin)

**Interfaces:**
- Produces: reachable Proxmox host at `192.168.1.53` on the home network.

- [ ] **Step 1:** Install Proxmox VE (matching etheirys's major version) with the **default single-disk LVM layout** — this yields `local-lvm` (thin), the restore target.
- [ ] **Step 2:** During install, set management IP `192.168.1.53/24`, gateway `192.168.1.1`, on the onboard NIC.
- [ ] **Step 3: Verify reachability**

Run (from the dev machine): `ping -c3 192.168.1.53 && ssh root@192.168.1.53 'pveversion'`
Expected: replies, and `pve-manager/...` version string.

---

## Task 8: Recreate the bridges (VLAN-aware)

**Files:**
- Modify: `/etc/network/interfaces` on the 7050 (`root@192.168.1.53`)

**Interfaces:**
- Consumes: reachable host from Task 7.
- Produces: vmbr2 (untagged/home, host IP), vmbr3 (VLAN 3/IoT), vmbr4 (VLAN 4/cluster) — the bridges every guest's `net0` references.

- [ ] **Step 1: Discover the onboard NIC name**

Run: `ssh root@192.168.1.53 'ls /sys/class/net | grep -E "^(eno|enp|eth)"'`
Expected: one physical NIC name (likely `eno1`). Call it `<NIC>` below.

- [ ] **Step 2: Write the bridge config** (substitute the real `<NIC>`)

Set `/etc/network/interfaces` to:
```
auto lo
iface lo inet loopback

iface <NIC> inet manual

auto <NIC>.3
iface <NIC>.3 inet manual

auto <NIC>.4
iface <NIC>.4 inet manual

auto vmbr2
iface vmbr2 inet static
	address 192.168.1.53/24
	gateway 192.168.1.1
	bridge-ports <NIC>
	bridge-stp off
	bridge-fd 0
#Home Network

auto vmbr3
iface vmbr3 inet manual
	bridge-ports <NIC>.3
	bridge-stp off
	bridge-fd 0
#Isolated Services

auto vmbr4
iface vmbr4 inet manual
	bridge-ports <NIC>.4
	bridge-stp off
	bridge-fd 0

source /etc/network/interfaces.d/*
```

- [ ] **Step 3: Apply and verify all three bridges are up**

Run: `ssh root@192.168.1.53 'ifreload -a && ip -br link show type bridge'`
Expected: `vmbr2`, `vmbr3`, `vmbr4` each listed `UP`. Host still reachable (you're on vmbr2).

---

## Task 9: Add the OMV backup storage on the 7050

**Files:**
- Modify: `/etc/pve/storage.cfg` on the 7050

**Interfaces:**
- Consumes: reachable host + network.
- Produces: `active` `nfs-backup` storage the restores read from.

- [ ] **Step 1: Append the storage definition**

Add to `/etc/pve/storage.cfg`:
```
nfs: nfs-backup
	export /mnt/birdpool/pvebackup
	path /mnt/pve/nfs-backup
	server 192.168.1.117
	content backup
```

- [ ] **Step 2: Verify it mounts and lists the five archives**

Run: `ssh root@192.168.1.53 'pvesm status | grep nfs-backup && pvesm list nfs-backup --content backup | grep -c vzdump'`
Expected: `active`, and a count ≥ 5.

---

## Task 10: Restore gitea first (Flux source)

**Files:** none (restores CT 124 to `local-lvm`)

**Interfaces:**
- Consumes: `nfs-backup`.
- Produces: running gitea CT at `192.168.200.52`, serving the Flux git source.

- [ ] **Step 1: Restore from the newest gitea archive**

Run:
```bash
ssh root@192.168.1.53 'BK=$(pvesm list nfs-backup --content backup | awk "/vzdump-lxc-124-/{print \$1}" | sort | tail -1); \
  echo "restoring $BK"; pct restore 124 "$BK" --storage local-lvm'
```
Expected: `successfully imported` / no `ERROR`. (If it complains the CT exists, it won't on a fresh host.)

- [ ] **Step 2: Start it and verify network + git service**

Run: `ssh root@192.168.1.53 'pct start 124 && sleep 20 && pct exec 124 -- ss -tlnp | grep -E ":22|:3000"'`
Expected: gitea SSH (22) and HTTP (3000) listeners present.

- [ ] **Step 3: Verify Flux can reach the source from the dev machine**

Run: `ping -c3 192.168.200.52`
Expected: replies (confirms vmbr4/VLAN 4 trunking works end-to-end). Full Flux reconcile is checked in Task 13 once kube-vm is up.

---

## Task 11: Restore mqtt, vaultwarden, hass

**Files:** none (restores CTs 101, 113, 100)

**Interfaces:**
- Consumes: `nfs-backup`.
- Produces: running mqtt (.100.3), vaultwarden (.100.6), hass (.1.123).

- [ ] **Step 1: Restore and start all three**

Run:
```bash
ssh root@192.168.1.53 'for id in 101 113 100; do \
  BK=$(pvesm list nfs-backup --content backup | grep "vzdump-lxc-$id-" | awk "{print \$1}" | sort | tail -1); \
  echo "restoring CT $id from $BK"; pct restore $id "$BK" --storage local-lvm && pct start $id; done'
```
Expected: three `successfully imported` + each starts cleanly. (`grep` does the per-ID filtering; `awk` just prints column 1.)

- [ ] **Step 2: Verify each service**

Run:
```bash
ssh root@192.168.1.53 'pct exec 101 -- ss -tlnp | grep :1883; \
  pct exec 113 -- ss -tlnp | grep :8000; \
  pct exec 100 -- ss -tlnp | grep :8123'
```
Expected: mqtt broker on 1883, vaultwarden on 8000, Home Assistant on 8123.

- [ ] **Step 3: Confirm DHCP guests got their reserved IPs**

Run: `ping -c2 192.168.1.123 && ping -c2 192.168.100.6`
Expected: both reply (MACs preserved by restore → reservations matched).

---

## Task 12: Restore kube-vm (drop dead GPU line, then boot)

**Files:** none (restores VM 202)

**Interfaces:**
- Consumes: `nfs-backup`.
- Produces: running k3s node at `192.168.200.2` with a 300G-thin disk and no GPU passthrough.

- [ ] **Step 1: Restore the VM**

Run:
```bash
ssh root@192.168.1.53 'BK=$(pvesm list nfs-backup --content backup | awk "/vzdump-qemu-202-/{print \$1}" | sort | tail -1); \
  echo "restoring $BK"; qmrestore "$BK" 202 --storage local-lvm'
```
Expected: `restore ... finished successfully`. A warning about the 300G volume on a smaller pool is fine (sparse thin restore, ~50G real).

- [ ] **Step 2: Remove the AMD RX560 passthrough (that card is gone)**

Run: `ssh root@192.168.1.53 'qm set 202 --delete hostpci0'`
Expected: `update VM 202: -delete hostpci0`.

- [ ] **Step 3: Boot and confirm the node is reachable**

Run: `ssh root@192.168.1.53 'qm start 202' && sleep 60 && ping -c3 192.168.200.2`
Expected: VM starts; node answers ping.

---

## Task 13: Verify the cluster is healthy

**Files:** none

**Interfaces:**
- Consumes: running kube-vm + restored gitea.
- Produces: confirmed-healthy k3s + live Flux GitOps loop.

- [ ] **Step 1: Check the NixOS flannel boot quirk**

Run: `ssh robin@192.168.200.2 'ls -l /run/flannel/subnet.env'`
Expected: file exists. If missing: `ssh robin@192.168.200.2 'sudo systemctl restart k3s'`, wait 60s, recheck.

- [ ] **Step 2: Nodes and pods**

Run: `kubectl get nodes -o wide && kubectl get pods -A | grep -vE 'Running|Completed'`
Expected: kube-vm `Ready`; the second command prints only the header (nothing stuck). Allow a few minutes for images to re-pull (pods may briefly show `ContainerCreating`/`Pending`).

- [ ] **Step 3: Flux reconciles from restored gitea**

Run: `flux reconcile kustomization flux-system -n flux-system && flux get kustomizations -A`
Expected: reconcile succeeds; kustomizations show `Ready=True`. This proves the Flux source (gitea) survived the move.

---

## Task 14: Verify the LXC services end-to-end

**Files:** none

**Interfaces:**
- Consumes: restored CTs + cluster.
- Produces: confirmed user-facing functionality.

- [ ] **Step 1: Home Assistant + Thread**

Check `https://home.wrenspace.dev` loads (HTTP 200) and, in HA, that the OpenThread Border Router is discovered (Settings → Devices; mDNS works because hass is on the flat home net). 

- [ ] **Step 2: Vaultwarden**

Check `https://vault.wrenspace.dev` loads and unlock works (validates the vmbr3 → external-ingress path).

- [ ] **Step 3: MQTT**

Run: `ssh root@192.168.1.53 'pct exec 101 -- mosquitto_sub -h localhost -t \$SYS/broker/uptime -C 1'` (or check a subscribed IoT device reconnected).
Expected: broker responds.

- [ ] **Step 4: Ingress/TLS spot check** — load one k8s-hosted app (e.g. Jellyfin) and confirm valid cert + reachability.

**Cutover complete when Tasks 13–14 are all green. Only then consider etheirys's SSD free to repurpose.**

---

## Deferred follow-ups (separate maintenance windows — NOT part of cutover)

These are intentionally out of the downtime window. Track them, do them later.

- [ ] **Shrink kube-vm's disk to 128G.** Currently a 300G thin volume (~50G real) — fine as-is; shrink only for tidiness. Requires offline root-fs resize: attach a rescue ISO to VM 202, `e2fsck -f /dev/sda2`, `resize2fs /dev/sda2 120G`, shrink the partition, then `lvreduce -L 128G pve/vm-202-disk-1`, then `qm set 202 -scsi0 local-lvm:vm-202-disk-1,...,size=128G`. **Monitor thin-pool usage (`lvs -a`) until then.**
- [ ] **Intel HD630 QuickSync for Jellyfin.** VM 202 is already `machine: q35`, so add passthrough without recreating: identify the iGPU (`lspci -nn | grep VGA`), blacklist `i915` on the host / bind it to `vfio-pci`, then `qm set 202 -hostpci0 <id>,pcie=1` (host goes headless). Update Jellyfin transcode config to QuickSync. Until done, Jellyfin uses software transcode.
- [ ] **amphoreus RAM → 16GB** using one 8GB stick freed elsewhere (ZFS ARC is choked to ~782MB on 8GB) — per `docs/etheirys-retirement.md`.

## Rollback

If the 7050 rebuild fails at any point: etheirys's SSD is untouched. Reinstall RAM in the iMac (or temporary sticks), power it on, and the original guests boot as-is. Nothing was deleted from etheirys — only copied to OMV.
