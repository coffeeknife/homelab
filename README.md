# homelab

Self-hosted, GitOps-managed infrastructure for **wrenspace.dev** — a Kubernetes
cluster and supporting services that I design, deploy, and operate end to end.
Everything here is declarative: this repo is the source of truth, and
[Flux CD](https://fluxcd.io) continuously reconciles the cluster to match it.

> **Status:** mid-migration — retiring an aging host and currently down a node,
> so the cluster is temporarily consolidated onto a single k3s node. An arm64
> Raspberry Pi worker is being brought back to restore multi-node, multi-arch
> scheduling.

## Overview

- **~40 self-hosted services** across 29 namespaces (~65 pods), from media and
  productivity apps to the networking, identity, and storage layers that back them.
- **GitOps end to end** — every change lands as a commit; Flux applies it. No
  manual `kubectl apply`. Secrets live safely in git via Sealed Secrets.
- **Automated operations** — Renovate opens dependency-update PRs; host
  configuration is declarative (NixOS); app rollout is Helm + Flux.

## Stack

| Layer | Tooling |
|-------|---------|
| Orchestration | k3s (Kubernetes v1.35) on NixOS, running as a VM under Proxmox |
| GitOps / CD | Flux CD (source, kustomize, helm, notification controllers) |
| Networking | Traefik (ingress), MetalLB (load balancing), flannel (CNI), Cloudflare (public DNS/tunnel) |
| Certificates | cert-manager — automated TLS across all ingresses |
| Identity | lldap + Authelia — SSO / OIDC with role-based access for all users |
| Storage | Longhorn (block), NFS over a ZFS pool (bulk), local-path (PV data) |
| Data | MariaDB, PostgreSQL |
| Secrets | Sealed Secrets (encrypted, committed to git) |
| Observability | Uptime Kuma health checks; Prometheus / Grafana / Loki (being restored post-migration) |

## Architecture

The cluster normally runs as a **multi-node, mixed-architecture** setup — an
x86 control-plane node plus arm64 Raspberry Pi workers — so workloads schedule
across both `amd64` and `arm64`.

It is currently **consolidated onto a single k3s node** (OptiPlex, i7-7700 /
32GB) while I migrate hardware and retire an aging host; an arm64 Pi worker is
being brought back to restore multi-arch scheduling. Storage lives on a separate
Proxmox box serving a ZFS pool over NFS, keeping cluster and data on independent
hardware.

Gitea (the Flux source) and a couple of stateful services run in Proxmox LXCs
outside the cluster, so the GitOps loop has no circular dependency on the
workloads it manages.

## Services

- **Media:** Jellyfin, the *arr suite (Radarr / Sonarr / Lidarr / Prowlarr / Bazarr), qBittorrent, Komga, Kavita
- **Productivity:** Nextcloud, Paperless-ngx, Grocy, Immich, Vaultwarden
- **Home:** Home Assistant, MQTT (Zigbee / Matter)
- **Platform:** Traefik, cert-manager, MetalLB, Authelia + lldap, MariaDB, PostgreSQL, Ollama

## Repo layout

```
apps/           # all Kubernetes manifests (Flux Kustomizations + HelmReleases)
flux-system/    # Flux bootstrap and notification config
ansible/        # host/LXC provisioning playbooks
nixos/          # declarative config for the NixOS cluster host(s)
proxmox/        # Proxmox / LXC provisioning notes
docs/           # migration and operations runbooks
```

See [CLAUDE.md](CLAUDE.md) for repository conventions and operational details.
