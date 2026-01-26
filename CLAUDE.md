# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GitOps-first homelab infrastructure for the **wrenspace.dev** domain. Flux CD reconciles Kubernetes cluster state from this repo's `main` branch. The Flux source is an internal Gitea instance (`ssh://gitea@192.168.200.52/coffeeknife/homelab`).

## Key Commands

```bash
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
ansible/                 # Hardware provisioning playbooks + inventory
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

## Editing Rules

- **Config changes** → edit `manifests/values.yaml`
- **Chart version bumps** → edit `manifests/helmrelease.yaml`
- **New Helm repos** → add to `apps/helm-repos.yaml`
- **Deploy** → commit and push to `main`; Flux auto-reconciles (homelab kustomization: 5m, flux-system: 10m)

## Architecture Details

**Authentication chain:** LLDAP (user directory) → Authelia (SSO/OIDC/2FA/forward-auth) → apps. Multiple services use Authelia as their OIDC provider (Nextcloud, Paperless, Home Assistant, Jellyfin, Grafana, Immich).

**Ingress:** Traefik as ingress controller with cert-manager for automated TLS. Apps use Traefik middleware for forward auth (Authelia) and security headers.

**Storage:** Longhorn for distributed block storage; NFS volumes for large data (documents, photos, media).

**Database:** Shared MariaDB instance with per-app databases. Database resources (PVC, Secret, ConfigMap) are defined per-app.

**Secret reloading:** Apps use Stakater Reloader annotations to auto-restart on secret/configmap changes:
- `secret.reloader.stakater.com/reload: "secret-name"`
- `configmap.reloader.stakater.com/reload: "config-name"`

**Stateful services outside Flux:** Gitea runs on Proxmox outside the cluster (must remain external so Flux can pull from it). Do not migrate services documented in `proxmox/README.md` into Flux without owner sign-off.

## Conventions

- Prefer small, single-purpose commits (one app or infra change) to simplify Flux troubleshooting
- Namespace manifests are always colocated with the app to guarantee creation ordering
- Values are externalized into ConfigMaps (loaded via `valuesFrom` in HelmRelease) rather than inlined
