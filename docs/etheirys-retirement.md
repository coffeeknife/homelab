# Etheirys retirement plan

> **✅ DONE 2026-07-18.** The 7050 host is named **tau-ceti** (`192.168.1.119`),
> got the iMac's 2×16GB → 32GB, and now runs all guests. etheirys is powered
> off/retired. See `docs/etheirys-7050-cutover.md` for the executed cutover.
> **Still open:** bump amphoreus to 16GB with a freed 8GB stick (below); harvest
> + sell etheirys's PSU/i5-7400.

Plan to retire **etheirys** (iMac18,2 / Proxmox VE, `192.168.1.53`) by splitting
its roles across two DDR4 OptiPlex boxes, rather than cramming everything onto
amphoreus. Decided 2026-07-09.

## Why not just consolidate onto amphoreus

amphoreus (OptiPlex 3050 SFF) is a **2-slot / 32GB-max** board. kube-vm is a
~26GB VM (memory requests 15.2GB, 4 vCPU), so putting it *and* the NAS on one
32GB box leaves no headroom. A dedicated second box gives kube-vm its own 32GB
and room to grow.

## Target topology

| Box | Hardware | Role | RAM |
|-----|----------|------|-----|
| **new 7050 Micro** | OptiPlex 7050 Micro, i7-7700 (Kaby Lake, 4c/8t, HD630) | **kube-vm host** (k3s node) | **32GB** — the iMac's harvested 2×16GB DDR4-2400 SO-DIMMs |
| **amphoreus** | OptiPlex 3050 SFF, i5-7500T | NAS (OMV / birdpool) — **cannot move** (disks live in the SFF; a Micro has no 3.5" bay) | **16GB** (existing 8GB + one 8GB freed from the 7050) |
| **etheirys** | iMac18,2 | **retired / scrapped** | — |

### Hardware notes

- **7050 Micro purchase:** ~$145 OBO on eBay. Chosen over a 9020 Micro, which
  was rejected: Haswell / DDR3L, 16GB max, and HD4600 can't hardware-transcode
  HEVC. A true i7-7700 is 65W and the Micro is rated 35W, so expect throttling
  toward 7700T levels under sustained load — fine for a homelab node.
- **iMac RAM harvest:** confirmed **2×16GB** sticks (fits the 7050's 2 slots),
  DDR4-2400 SO-DIMM. A $0 RAM move.
- **amphoreus CPU:** leave the i5-7500T in place. The iMac's i5-7400 is *not* an
  upgrade (same 4c/4t, same HD630, only ~300MHz more clock, but 65W vs 35W). A
  real amphoreus CPU upgrade would be an i7-7700/7700T (adds hyperthreading).

## Migration is 4 workloads, not just kube-vm

etheirys also hosts three LXCs that must relocate before it can be powered off:

| LXC | ID | Notes |
|-----|-----|-------|
| mqtt | 101 | IoT broker |
| vaultwarden | 113 | password manager |
| **gitea** | 124 | **Flux source** — sequence its move **last** and carefully so the GitOps loop isn't down mid-migration |

## Cutover checklist (rough order)

> **Superseded by the executable runbook:
> [`etheirys-7050-cutover.md`](etheirys-7050-cutover.md).** The rough order below
> predates the *no-overlap* constraint (RAM harvested into the 7050 before it can
> boot). The runbook replaces the "migrate live to amphoreus" sketch with a
> **vzdump→OMV→restore** flow, restores **gitea first** (not last), and defers the
> disk shrink and GPU passthrough out of the downtime window. Follow the runbook.

1. Buy + set up the 7050 Micro; install Proxmox; add the iMac's 2×16GB.
2. Move kube-vm's ~300GB virtual disk to the 7050 (it holds all `local-path`
   PVs: Prometheus, Loki, MariaDB data, Immich postgres — verify free space).
3. Reconfigure Jellyfin transcode from the AMD GPU to **Intel QuickSync
   (HD630)** and pass the 7050's iGPU into the kube-vm VM (host goes headless).
4. Migrate the mqtt and vaultwarden LXCs to amphoreus (or the 7050).
5. Migrate the **gitea** LXC last; confirm Flux still reconciles from it.
6. Move one 8GB stick from the 7050 into amphoreus (→ 16GB); confirm ZFS ARC has
   room (currently choked to ~782MB on 8GB).
7. Power off etheirys; harvest parts (below).

## Etheirys end-of-life (parts)

The iMac has a **cracked display** and a **shorted display connector on the
logic board**, so it is **not** being sold whole — the panel and board have no
resale value (a board only sells to iMac repairers who need working display
output).

- **Keep:** the 2×16GB RAM (→ 7050); the **aftermarket SSD** (spare storage).
- **Sell:** the internal **PSU** and the **i5-7400 CPU** (loose — the shorted
  board won't sell, so pull the CPU).
- **Recycle:** cracked 4K panel + shorted logic board; parts-bin the fan and
  Wi-Fi/BT card.
