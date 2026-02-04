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
| 200 | VM | kube-1 | 2 CPU, 10GB | 192.168.200.2 | K8s control plane |
| 201 | VM | kube-2 | 1 CPU, 10GB | 192.168.200.3 | K8s worker |
| 202 | VM | kube-3 | 1 CPU, 10GB | 192.168.200.4 | K8s worker |
| 101 | LXC | mqtt | 1 CPU, 512MB | 192.168.100.3 | MQTT broker (IoT network) |
| 113 | LXC | vaultwarden | 1 CPU, 256MB | DHCP | Password manager |
| 124 | LXC | gitea | 1 CPU, 1GB | 192.168.200.52 | Git server (Flux source) |

## Kubernetes Cluster

3-node MicroK8s cluster running on VMs hosted on etheirys (Proxmox). Control plane on kube-1.

| Node | IP | Resources | Notes |
|------|-----|-----------|-------|
| kube-1 | 192.168.200.2 | 2 CPU, 10GB RAM | Control plane |
| kube-2 | 192.168.200.3 | 1 CPU, 10GB RAM | Worker |
| kube-3 | 192.168.200.4 | 1 CPU, 10GB RAM | Worker |

- **Kubernetes version:** v1.33.7
- **OS:** Ubuntu 24.04 LTS
- **CNI:** Cilium
- **Container runtime:** containerd 1.7.27
- **MetalLB IP range:** 192.168.200.100–192.168.200.254
- **Storage classes:** `longhorn` (default), `longhorn-static`
- **Sealed Secrets:** Used for encrypting secrets in Git
- **Resource constraints:** Cluster is CPU-constrained; use minimal requests for batch jobs (50m CPU, 256Mi memory)

## Gitea Access

- **SSH (Flux source):** `ssh://gitea@192.168.200.52/coffeeknife/homelab`
- **HTTPS API:** `https://git.wrenspace.dev/api/v1` (use for tools like Renovate)
- **Renovate token scopes:** `read:user`, `read:repository`, `write:repository`, `write:issue`

## Key Commands

```bash
# kubectl and flux are configured on the local dev machine — no need to SSH into nodes

# Check Flux kustomization status
flux get kustomizations -n flux-system

# Check all Helm releases
flux get helmreleases -A

# Force reconciliation after pushing changes
flux reconcile kustomization flux-system -n flux-system

# Generate Authelia OIDC client secret pair
docker run --rm authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986

# Run Ansible playbooks (e.g., apt updates)
ansible-playbook -i ansible/inventory/inventory.yaml ansible/playbooks/update-apt.yaml
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
