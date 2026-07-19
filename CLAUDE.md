# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GitOps-first homelab infrastructure for the **wrenspace.dev** domain. Flux CD reconciles Kubernetes cluster state from this repo's `main` branch. The Flux source is an internal Gitea instance (`ssh://gitea@192.168.200.52/coffeeknife/homelab`).

## Hardware

| Host | Hardware | OS | Role | IP |
|------|----------|-----|------|-----|
| tau-ceti | Dell OptiPlex 7050 Micro | Proxmox VE 9.2.4 | Hypervisor — runs all LXCs + the kube-vm k3s VM (**replaced etheirys 2026-07-18**) | 192.168.1.119 |
| etheirys | iMac (iMac18,2) | — | **RETIRED 2026-07-18** — powered off; all guests migrated to tau-ceti; SSD kept as fallback | 192.168.1.53 (freed) |
| amphoreus | Dell OptiPlex | Proxmox VE | Hypervisor — runs OpenMediaVault (NAS); hosts the migrated `birdpool` ZFS pool | 192.168.1.31 |
| vulcan | Raspberry Pi 4 | Armbian | **Idle / standby** — former NAS; `birdpool` ZFS pool migrated to amphoreus/OMV, awaiting repurpose | 192.168.1.69 |
| gunsmoke | Raspberry Pi 3B | DietPi | **Decommissioned** — was IoT hub; stacks moved to gallifrey | 192.168.100.2 |
| gallifrey | Raspberry Pi 4 | NixOS | Docker compose stacks only (zigbee/thread/diun/act-runner, formerly on gunsmoke) — **removed from k3s 2026-07-08** | 192.168.1.54 |

### Gunsmoke (IoT Hub) — decommissioned

Currently powered down / not running its stacks. The zigbee2mqtt and
Matter/Thread compose stacks now run on **gallifrey** (see
`nixos/hosts/gallifrey/compose/`).

If gunsmoke comes back online for any reason:
- SSH: `ssh root@192.168.100.2` (hostname `gunsmoke` not in DNS)
- `docker ps -a` — check container status
- `usbreset '10c4:ea60'` — reset SONOFF Thread dongle if unresponsive
- Watchtower requires `DOCKER_API_VERSION=1.44` env var due to ARM64 build bug

### Gallifrey (RPi4) — compose host, not a cluster node

Colmena-managed NixOS host (`ssh root@192.168.1.54`) running the Docker
compose stacks (zigbee/thread/diun/act-runner). **Removed from the k3s
cluster 2026-07-08** — it is no longer a node; `kube-vm` is the sole cluster
node. Its config (`nixos/hosts/gallifrey/default.nix`) no longer imports
`modules/k3s-agent.nix`.

- **Bootloader: stock `generic-extlinux-compatible`, NOT nixos-raspberrypi's
  `kernel`/`uboot` builder.** Those builders re-copy the ~22MB RPi vendor
  firmware into the tiny 30MB FAT `FIRMWARE` partition on every activation,
  which overflows it and corrupts boot. gallifrey disables nixos-raspberrypi's
  bootloader (`boot.loader.raspberry-pi.enable = mkForce false`) + GRUB and
  uses stock extlinux, which writes only to ext4 `/boot`. The FAT firmware +
  `u-boot-rpi4.bin` + `config.txt` are a static one-time setup; U-Boot on the
  FAT chain-loads the ext4 extlinux config. Reboot-safe (verified 2026-07-08).
- **Colmena deploys must build on the target:** `colmena apply --on gallifrey
  --build-on-target` (this x86 machine can't build aarch64 without emulation;
  the Pi builds natively, kernel comes from `nixos-raspberrypi.cachix.org`).
- **vulcan carries the same latent `bootloader = "kernel"` setting** but is
  idle — if it's ever redeployed/rebooted, apply the same extlinux fix first.

### NAS — OpenMediaVault on amphoreus

The `birdpool` ZFS pool was migrated off vulcan onto **amphoreus** (Dell OptiPlex,
Proxmox VE, `192.168.1.31`) to give it more CPU/RAM. It is served by an
**OpenMediaVault** VM at `192.168.1.117`, which is now the NFS backend for the
cluster (nfs-provisioner dynamic PVCs + the static NFS PVs in `media`,
`services`, etc.).

- **NFS server IP:** `192.168.1.117` (was vulcan `192.168.1.69`).
- **Pool / paths:** still named `birdpool`; on-disk paths remain `/mnt/birdpool/...`.
- **OMV shares are configured manually.** Unlike vulcan's kernel-exports, each
  NFS share must be created in the OMV web UI before the corresponding volume
  will mount. When migrating/adding a volume, create its OMV NFS share first,
  then update the manifest's `server:` (and `path:` if OMV's export path
  differs). See `docs/nfs-migration-omv.md` for the per-volume checklist.
- **Storage-class names unchanged:** the `vulcan-nfs` / `vulcan-nfs-strict`
  StorageClasses keep their names for compatibility (baked into ~15 PVCs); only
  the backing `server:` IP changes. Don't rename them.

### Vulcan — idle / standby

Powered on but has no active role since `birdpool` moved to amphoreus. Its NixOS
config (`nixos/hosts/vulcan/`, colmena target `192.168.1.69`) and NAS module are
left in place pending a decision on repurposing. Not serving NFS/Samba.

### tau-ceti (7050) — cluster/guest hypervisor

Dell OptiPlex 7050 Micro (i7-7700, 32GB DDR4), Proxmox VE 9.2.4, `ssh
root@192.168.1.119`. **Replaced etheirys on 2026-07-18** via a no-overlap
vzdump→OMV→restore of all five guests (runbook `docs/etheirys-7050-cutover.md`).
Kept the management IP at **192.168.1.119** (not etheirys's `.53` — nothing
depends on the hypervisor's mgmt IP; only docs/ssh aliases referenced `.53`).

- **Networking:** onboard NIC is renamed **`nic0`** (Proxmox 9 stable naming).
  Bridges mirror etheirys's structure over the one trunk port:
  **vmbr2** (untagged/home, holds host `.119`), **vmbr3** (`nic0.3`, VLAN 3/IoT),
  **vmbr4** (`nic0.4`, VLAN 4/cluster). The switch port must trunk VLANs 3 & 4
  tagged + untagged home.
- **AC power recovery must be set in BIOS by hand** (F2 → Power Management →
  AC Recovery → "Power On"). No OS path: `libsmbios` is `/dev/mem`-blocked and
  deprecated, and `dell-wmi-sysman` isn't exposed by the 7050 firmware.
- **kube-vm GPU passthrough is gone** (the AMD RX560 stayed with etheirys); the
  `hostpci0` line was stripped, Jellyfin runs software transcode until the host's
  Intel HD630 QuickSync is passed through later (VM is already `q35`).
- **Guests all restored with `onboot=1` + startup order** (gitea → mqtt →
  vaultwarden → hass → kube-vm) so a reboot brings the homelab back on its own.

### etheirys (iMac) — retired

Powered off 2026-07-18. Its SSD is left intact as a rollback fallback until
tau-ceti is long-proven; don't wipe it prematurely. PSU + i5-7400 harvested for
resale; RAM (2×16GB) moved into tau-ceti. See `docs/etheirys-retirement.md`.

### Proxmox VMs/LXCs on tau-ceti

| ID | Type | Name | Resources | IP | Role |
|----|------|------|-----------|-----|------|
| 202 | VM | kube-vm | 26.6GB, 4 vCPU | 192.168.200.2 | k3s single-node (**no GPU passthrough since 2026-07-18**); 300G thin disk (~117G real) |
| 100 | LXC | hass | — | 192.168.1.123 | Home Assistant (Debian, host-net; recorder→MariaDB) |
| 101 | LXC | mqtt | 1 CPU, 512MB | 192.168.100.3 | MQTT broker (IoT network) |
| 113 | LXC | vaultwarden | 1 CPU, 256MB | 192.168.100.6 | Password manager |
| 124 | LXC | gitea | 1 CPU, 1GB | 192.168.200.52 | Git server (Flux source) |

> **Restore caveat — kube-vm's `efidisk0`:** the restored config has a dangling
> `efidisk0` pointing at the *same* LV as `scsi0` (`vm-202-disk-0`). It's inert
> because the VM is `bios: seabios`. **Never `qm set 202 --delete efidisk0`** — it
> would remove the shared LV and destroy the root disk. Clean it (if ever) only by
> editing `/etc/pve/qemu-server/202.conf` directly.

### Vaultwarden LXC (113)

Alpine Linux, OpenRC (no systemd). Fronted by Traefik via `apps/external-ingress/manifests/vaultwarden.yaml` (Endpoints hard-codes `192.168.100.6:8000`).

- **Config:** `/etc/conf.d/vaultwarden` (env-style `export KEY=value`). `DOMAIN` **must** match the public hostname (`https://vault.wrenspace.dev`); built-in CORS only echoes back `Origin` when it equals `DOMAIN` or `file://`, and email/WebAuthn URLs are derived from it.
- **Data:** `/var/lib/vaultwarden/db.sqlite3`. Service: `rc-service vaultwarden {start,stop,restart,status}`.
- **Logs:** the OpenRC service doesn't set `output_log`, so stdout/stderr → `/dev/null`. `/var/log/vaultwarden/*.log` are stale (last write Dec 2024). To get live logs, edit the openrc service or run vaultwarden under a foreground supervisor.
- **Pinned to Alpine edge:** `vaultwarden` and `vaultwarden-web-vault` are tagged `@edge` in `/etc/apk/world` (repo line `@edge http://dl-cdn.alpinelinux.org/alpine/edge/community` in `/etc/apk/repositories`). Alpine stable lags Bitwarden client releases — pre-1.36 missed `/identity/accounts/prelogin/password` and broke extension login. `apk upgrade` will only pull edge for those two tagged packages.
- **Extension CORS:** Vaultwarden refuses to echo extension origins (`moz-extension://`, `chrome-extension://`) because they don't match `DOMAIN`. The `vaultwarden-cors` Traefik middleware in the Ingress manifest injects `Access-Control-Allow-Origin` for those — do not remove it.

## Kubernetes Cluster

Single-node k3s cluster (embedded etcd) running on a NixOS VM hosted on **tau-ceti** (Proxmox; was etheirys until 2026-07-18). Embedded etcd is enabled so additional nodes can join from other machines in future.

| Node | IP | Resources | Notes |
|------|-----|-----------|-------|
| kube-vm | 192.168.200.2 | 26.6GB, 4 vCPU | **No GPU passthrough since 2026-07-18** (AMD RX560 retired with etheirys); Jellyfin on software transcode until Intel HD630 QuickSync is passed through |

- **Kubernetes version:** v1.35.4+k3s1
- **OS:** NixOS 26.05 (Yarara) — managed via colmena from `nixos/`
- **CNI:** Flannel (k3s embedded, VXLAN backend, VNI 1)
- **Container runtime:** containerd 2.1.5-k3s1
- **MetalLB IP range:** 192.168.200.100–192.168.200.254
- **Kubernetes API VIP:** 192.168.200.102 (MetalLB)
- **Storage classes:** `vulcan-nfs` (default), `vulcan-nfs-strict`, `local-path`
- **Sealed Secrets:** Used for encrypting secrets in Git
- **Resource constraints:** Use minimal requests for batch jobs (50m CPU, 256Mi memory)

### Known NixOS/k3s quirk

`/run/flannel/subnet.env` lives on tmpfs and must exist for pod sandbox creation. A `systemd.tmpfiles` rule in `nixos/modules/k3s-server.nix` creates `/run/flannel` at boot so k3s can write this file. If pods are stuck in `ContainerCreating` after a reboot, check this file exists on each node:

```bash
ssh kube-vm "ls /run/flannel/subnet.env"
```

If missing, restart k3s: `sudo systemctl restart k3s`

## Gitea Access

- **SSH (Flux source):** `ssh://gitea@192.168.200.52/coffeeknife/homelab`
- **HTTPS API:** `https://git.wrenspace.dev/api/v1` (use for tools like Renovate)
- **Renovate token scopes:** `read:user`, `read:repository`, `write:repository`, `write:issue`

## Key Commands

```bash
# kubectl and flux are configured on the local dev machine — no need to SSH into nodes

# Check Flux kustomization status
flux get kustomizations -A

# Check all Helm releases
flux get helmreleases -A

# Force reconciliation after pushing changes
flux reconcile kustomization flux-system -n flux-system

# Deploy NixOS changes to all cluster nodes
colmena apply

# Deploy NixOS changes to a single node
colmena apply --on kube-3

# Generate Authelia OIDC client secret pair
docker run --rm authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986

# SSH to cluster nodes (configured in ~/.ssh/config)
ssh kube-vm  # 192.168.200.2
```

## Repository Layout

```
apps/                    # Flux-managed Kubernetes apps (HelmReleases + manifests)
  auth/                  # Authelia (SSO/OIDC) + LLDAP (LDAP directory)
  infrastructure/        # cert-manager, traefik, metallb, nfs-provisioner, cloudflare-operator, smtp-relay, kube-system (system patches + node-maintenance CronJobs)
  database/              # Shared MariaDB
  services/              # User-facing apps (nextcloud, paperless-ngx, home-assistant, immich, grocy, homepage)
  media/                 # jellyfin, arr suite (radarr, sonarr, etc.)
  monitoring/            # prometheus, grafana, loki, apprise
  external-ingress/      # External DNS/routing
  helm-repos.yaml        # All HelmRepository definitions
flux-system/             # Flux CD bootstrap (gotk-sync.yaml, gotk-components.yaml)
nixos/                   # NixOS configuration for k3s cluster nodes (deployed via colmena)
  hosts/                 # Per-node config (kube-1, kube-2, kube-3)
  modules/               # Shared modules (k3s-server, disk, common)
  secrets/               # sops-encrypted secrets
ansible/                 # Legacy — inventory is outdated, leave as-is
proxmox/                 # Proxmox VE helper script configs (LXC provisioning)
```

## Per-App Convention

Every app follows this directory pattern: `apps/<category>/<app-name>/manifests/`

Common files inside `manifests/`:
- `helmrelease.yaml` — chart source, version, release strategy
- `values.yaml` — runtime Helm values (externalized via ConfigMap)
- `namespace.yaml` — namespace definition (colocated to guarantee creation order)
- `kustomization.yaml` — bundles resources, uses `configMapGenerator` with `disableNameSuffixHash: true`
- `secrets.yaml` / `creds.yaml` — Kubernetes Secrets (review carefully, no plaintext without approval)
- `middlewares.yaml` — Traefik middleware (forward auth, headers)
- `tunnelbinding.yaml` — Cloudflare tunnel bindings (optional)
- `nfs-volume.yaml` — NFS persistent storage (optional)

## Labeling Standard

All Kubernetes resources should include consistent labels for filtering, debugging, and tooling compatibility.

### Required Labels

| Label | Value | Applies To |
|-------|-------|------------|
| `app.kubernetes.io/name` | app name (e.g., `paperless`) | All resources |
| `app.kubernetes.io/part-of` | category (e.g., `services`, `media`, `auth`) | All resources |

### Optional Labels

| Label | Value | When to Use |
|-------|-------|-------------|
| `app.kubernetes.io/component` | `server`, `database`, `cache`, etc. | Multi-component apps |
| `app.kubernetes.io/instance` | instance name | Multiple instances of same app |

### Label Placement

```yaml
# Namespace
metadata:
  name: paperless
  labels:
    name: paperless  # legacy, keep for compatibility
    app.kubernetes.io/name: paperless
    app.kubernetes.io/part-of: services

# Deployment/Service/Ingress
metadata:
  labels:
    app.kubernetes.io/name: paperless
    app.kubernetes.io/part-of: services
spec:
  selector:
    matchLabels:
      app: paperless  # simple selector
  template:
    metadata:
      labels:
        app: paperless
        app.kubernetes.io/name: paperless

# HelmRelease
metadata:
  labels:
    app.kubernetes.io/name: authelia
    app.kubernetes.io/part-of: auth
```

### Current State

Labels are partially implemented. When modifying existing resources, add missing labels. New resources must include all required labels.

## Editing Rules

- **Config changes** → edit `manifests/values.yaml`
- **Chart version bumps** → edit `manifests/helmrelease.yaml`
- **New Helm repos** → add to `apps/helm-repos.yaml`
- **Deploy** → commit and push to `main`; Flux auto-reconciles (homelab kustomization: 5m, flux-system: 10m)
- **Image tag bumps** → before pinning a Docker image version, query the registry (Docker Hub `/v2/repositories/<image>/tags`, GHCR API, etc.) and pick a recent tag. Don't reuse what's currently in the manifest or guess from training data — both go stale.

## Architecture Details

**Authentication chain:** LLDAP (user directory) → Authelia (SSO/OIDC/2FA/forward-auth) → apps. Multiple services use Authelia as their OIDC provider (Nextcloud, Paperless, Home Assistant, Jellyfin, Grafana, Immich).

**Ingress:** Traefik as ingress controller with cert-manager for automated TLS. Apps use Traefik middleware for forward auth (Authelia) and security headers.

**Storage:** NFS provisioner backed by **OpenMediaVault on amphoreus** (`192.168.1.117`, `birdpool` ZFS pool over NFS) is the default storage class (`vulcan-nfs`). The `vulcan-nfs*` names are retained for compatibility — the backend moved off vulcan to OMV but the class names stayed (see the NAS section above). Three storage classes are available:
- `vulcan-nfs` (default) — general-purpose, retain-on-delete, noatime mount; use for app config/data
- `vulcan-nfs-strict` — same as above but with cache disabled (`noac`, `sync`, `actimeo=0`); use for databases and anything requiring strong consistency (Redis, MariaDB backups)
- `local-path` — node-local ephemeral storage via k3s provisioner; use for databases that need low-latency I/O (Prometheus, Loki, MariaDB data, Immich postgres)

NFS PVC paths follow `{namespace}/{pvc-name}` under the `birdpool` pool on OMV. Large read-only datasets (media, documents, photos) use static NFS PVs defined in `nfs-volume.yaml` per app. Adding/migrating a static NFS volume requires creating the matching NFS share in the OMV web UI first — see `docs/nfs-migration-omv.md`.

**Database:** Shared MariaDB instance with per-app databases. Database resources (PVC, Secret, ConfigMap) are defined per-app.

**Secret reloading:** Apps use Stakater Reloader annotations to auto-restart on secret/configmap changes:
- `secret.reloader.stakater.com/reload: "secret-name"`
- `configmap.reloader.stakater.com/reload: "config-name"`

**Stateful services outside Flux:** Gitea runs on Proxmox outside the cluster (must remain external so Flux can pull from it). Do not migrate services documented in `proxmox/README.md` into Flux without owner sign-off.

## Conventions

- Always push immediately after committing
- Prefer small, single-purpose commits (one app or infra change) to simplify Flux troubleshooting
- Namespace manifests are always colocated with the app to guarantee creation ordering
- Values are externalized into ConfigMaps (loaded via `valuesFrom` in HelmRelease) rather than inlined
