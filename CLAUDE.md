# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GitOps-first homelab infrastructure for the **wrenspace.dev** domain. Flux CD reconciles Kubernetes cluster state from this repo's `main` branch. The Flux source is an internal Gitea instance (`ssh://gitea@192.168.200.52/coffeeknife/homelab`).

## Hardware

| Host | Hardware | OS | Role | IP |
|------|----------|-----|------|-----|
| etheirys | iMac | Proxmox VE | Hypervisor — runs LXCs and Kubernetes VMs | 192.168.1.53 |
| vulcan | Raspberry Pi 4 | Armbian | NAS — ZFS pool shared over NFS and Samba | 192.168.1.69 |
| gunsmoke | Raspberry Pi 3B | DietPi | IoT hub — zigbee2mqtt + Matter/Thread servers (Docker) | 192.168.100.2 |

### Gunsmoke (IoT Hub) Access

SSH: `ssh root@192.168.100.2` (hostname `gunsmoke` not in DNS)

Common Docker commands:
- `docker ps -a` — check container status
- `usbreset '10c4:ea60'` — reset SONOFF Thread dongle if unresponsive
- Watchtower requires `DOCKER_API_VERSION=1.44` env var due to ARM64 build bug

### Proxmox VMs/LXCs on etheirys

| ID | Type | Name | Resources | IP | Role |
|----|------|------|-----------|-----|------|
| 200 | VM | kube-1 | 2 CPU, 10GB | 192.168.200.2 | k3s node (bootstrap) |
| 201 | VM | kube-2 | 1 CPU, 10GB | 192.168.200.3 | k3s node |
| 202 | VM | kube-3 | 1 CPU, 10GB | 192.168.200.4 | k3s node (AMD GPU passthrough) |
| 101 | LXC | mqtt | 1 CPU, 512MB | 192.168.100.3 | MQTT broker (IoT network) |
| 113 | LXC | vaultwarden | 1 CPU, 256MB | DHCP | Password manager |
| 124 | LXC | gitea | 1 CPU, 1GB | 192.168.200.52 | Git server (Flux source) |

## Kubernetes Cluster

3-node k3s HA cluster (embedded etcd) running on NixOS VMs hosted on etheirys (Proxmox). All three nodes are control-plane + etcd members. kube-1 bootstraps the cluster; kube-2 and kube-3 join via `serverAddr`.

| Node | IP | Resources | Notes |
|------|-----|-----------|-------|
| kube-1 | 192.168.200.2 | 2 CPU, 10GB RAM | Cluster bootstrap node |
| kube-2 | 192.168.200.3 | 1 CPU, 10GB RAM | |
| kube-3 | 192.168.200.4 | 1 CPU, 10GB RAM | AMD GPU passthrough (`gpu=amd` label) — Jellyfin schedules here |

- **Kubernetes version:** v1.34.4+k3s1
- **OS:** NixOS 26.05 (Yarara) — managed via colmena from `nixos/`
- **CNI:** Flannel (k3s embedded, VXLAN backend, VNI 1)
- **Container runtime:** containerd 2.1.5-k3s1
- **MetalLB IP range:** 192.168.200.100–192.168.200.254
- **Kubernetes API VIP:** 192.168.200.102 (MetalLB)
- **Storage classes:** `longhorn` (default), `longhorn-static`
- **Sealed Secrets:** Used for encrypting secrets in Git
- **Resource constraints:** Cluster is CPU-constrained; use minimal requests for batch jobs (50m CPU, 256Mi memory)

### Known NixOS/k3s quirk

`/run/flannel/subnet.env` lives on tmpfs and must exist for pod sandbox creation. A `systemd.tmpfiles` rule in `nixos/modules/k3s-server.nix` creates `/run/flannel` at boot so k3s can write this file. If pods are stuck in `ContainerCreating` after a reboot, check this file exists on each node:

```bash
ssh kube-1 "ls /run/flannel/subnet.env"
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
ssh kube-1   # 192.168.200.2
ssh kube-2   # 192.168.200.3
ssh kube-3   # 192.168.200.4
```

## Repository Layout

```
apps/                    # Flux-managed Kubernetes apps (HelmReleases + manifests)
  auth/                  # Authelia (SSO/OIDC) + LLDAP (LDAP directory)
  infrastructure/        # cert-manager, traefik, metallb, longhorn, cloudflare-operator, smtp-relay
  database/              # Shared MariaDB
  services/              # User-facing apps (nextcloud, paperless-ngx, home-assistant, immich, grocy, homepage)
  media/                 # jellyfin, arr suite (radarr, sonarr, etc.)
  monitoring/            # prometheus, grafana, loki, apprise
  external-ingress/      # External DNS/routing
  helm-repos.yaml        # All HelmRepository definitions
flux-system/             # Flux CD bootstrap (gotk-sync.yaml, gotk-components.yaml)
nixos/                   # NixOS configuration for k3s cluster nodes (deployed via colmena)
  hosts/                 # Per-node config (kube-1, kube-2, kube-3)
  modules/               # Shared modules (k3s-server, longhorn-prereqs, disk, common)
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

## Architecture Details

**Authentication chain:** LLDAP (user directory) → Authelia (SSO/OIDC/2FA/forward-auth) → apps. Multiple services use Authelia as their OIDC provider (Nextcloud, Paperless, Home Assistant, Jellyfin, Grafana, Immich).

**Ingress:** Traefik as ingress controller with cert-manager for automated TLS. Apps use Traefik middleware for forward auth (Authelia) and security headers.

**Storage:** Longhorn for distributed block storage; NFS volumes from vulcan (ZFS) for large data (documents, photos, media).

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
