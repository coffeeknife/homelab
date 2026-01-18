# Copilot / AI Agent Instructions for this repository

This repository is a GitOps-first homelab. The notes below focus on the repo layout, Flux-driven delivery, per-app patterns, and concrete edit examples an AI agent should follow to be productive immediately.

**Big Picture**
- **GitOps:** Flux (GitRepository + Kustomization + HelmReleases) drives cluster state. Inspect `flux-system/flux-system/gotk-sync.yaml` and `flux-system/flux-system/kustomization.yaml` to find repo sources and inclusion order.
- **Apps:** Cluster-managed apps live under `apps/` and are included by the `./apps` kustomization.
- **Stateful / external:** Long-lived services are documented under `proxmox/README.md` and are intentionally managed outside Flux.

**Per-App Layout (convention)**
- **Directory:** `apps/<category>/<name>/manifests/`
- **Common files:** `helmrelease.yaml`, `values.yaml`, `namespace.yaml`, `secrets*.yaml` or `creds.yaml`, sometimes `tunnelbinding.yaml`.
- **Rule:** Prefer editing `manifests/values.yaml` for runtime configuration; change `helmrelease.yaml` for chart/repo/version or release strategy changes.

**How to make a cluster-facing change**
- **Edit:** Update `apps/<category>/<name>/manifests/values.yaml` for config and `apps/<category>/<name>/manifests/helmrelease.yaml` for chart bumps.
- **Commit:** Push to `main` (Flux reads the `main` branch per `gotk-sync.yaml`).
- **Verify / reconcile (examples):**
  - `flux get kustomizations -n flux-system`
  - `flux get helmreleases -A`
  - `flux reconcile kustomization flux-system -n flux-system`

**Developer workflows & tooling**
- **Primary flow:** Make a focused repo change → push → Flux applies. Use the `flux` CLI to inspect and force reconciliation when needed.
- **Out-of-cluster tasks:** Ansible playbooks live in `ansible/playbooks/` (example: `update-apt.yaml`).

**Integration points & external dependencies**
- **Cloudflare operator:** Managed via a separate GitRepository referenced in Flux (see `flux-system/.../gotk-sync.yaml`).
- **Platform components:** `cert-manager`, `traefik`, `metallb`, and `longhorn` are under `apps/infrastructure/*` as HelmReleases.
- **Git remote:** The Flux source uses an internal Gitea (`ssh://gitea@192.168.200.52/...`). Ensure you have push access before updating `main`.

**Conventions & cautionary notes**
- **Namespaces:** Namespace manifests are colocated with releases to guarantee creation ordering.
- **Secrets:** Secrets are stored per-app in `manifests/`. Review carefully and do not add plaintext secrets without approval.
- **Stateful services:** Do not migrate services documented in `proxmox/README.md` into Flux without owner sign-off.
- **Small PRs:** Prefer small, single-purpose PRs (one app or infra change) to simplify Flux troubleshooting.

**Quick references**
- **Edit config:** `apps/services/homepage/manifests/values.yaml`
- **Bump chart/version:** `apps/services/homepage/manifests/helmrelease.yaml`
- **Flux source:** `flux-system/flux-system/gotk-sync.yaml`

If something is missing or you want targeted examples for a specific app (for example `home-assistant` or `nextcloud`), tell me which app and I will add a short, targeted example.
  - Inspect Flux source: `flux-system/flux-system/gotk-sync.yaml`
