---
name: new-app
description: Use when adding a new app to this homelab GitOps repo — scaffolds apps/<category>/<app>/ with the Flux Kustomization CR plus the manifests/ bundle (namespace, helmrelease, values, kustomization) following the repo's per-app convention and labeling standard. Triggers include "add a new app", "scaffold an app", "deploy a new service", "new HelmRelease".
---

# Scaffold a New App

## Overview

Every app is **two layers**:

1. **`apps/<category>/<app>/<app>.yaml`** — a Flux `Kustomization` CR
   (`kustomize.toolkit.fluxcd.io/v1`) that tells Flux to reconcile the manifests
   dir. Sourced from GitRepository `homelab`. Flux discovers this file
   automatically on the next reconcile — no parent aggregator to edit.
2. **`apps/<category>/<app>/manifests/`** — the actual resources, bundled by a
   kustomize `kustomization.yaml`.

`<category>` is one of: `infrastructure`, `auth`, `database`, `services`, `media`,
`monitoring`, `external-ingress`.

## Files to create

| File | Purpose |
|------|---------|
| `<app>.yaml` | Flux Kustomization CR (layer 1) |
| `manifests/namespace.yaml` | Namespace (colocated to guarantee creation order) |
| `manifests/helmrelease.yaml` | HelmRepository + HelmRelease |
| `manifests/values.yaml` | Helm values (loaded via ConfigMap, not inlined) |
| `manifests/kustomization.yaml` | Bundles resources + `configMapGenerator` for values |

Add `secrets.yaml` (via the `seal-secret` skill), `nfs-volume.yaml`, `ingress`, etc.
only as needed.

## Labeling standard (required on every resource)

```yaml
app.kubernetes.io/name: <app>
app.kubernetes.io/part-of: <category>
```

Namespaces also keep the legacy `name: <app>` label.

## Layer 1 — `apps/<category>/<app>/<app>.yaml`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: homelab
  path: ./apps/<category>/<app>/manifests
  prune: true
  wait: true
  # dependsOn only if this app needs another Flux Kustomization first:
  # dependsOn:
  #   - name: mariadb      # apps needing the shared DB
  #   - name: lldap        # apps behind Authelia/LDAP
```

## Layer 2 — the `manifests/` bundle

`namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app>
  labels:
    name: <app>
    app.kubernetes.io/name: <app>
    app.kubernetes.io/part-of: <category>
```

`kustomization.yaml` (values are externalized into a ConfigMap, never inlined into
the HelmRelease):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
configMapGenerator:
  - name: <app>-values
    namespace: <app>
    files:
      - values.yaml
    options:
      disableNameSuffixHash: true
```

`helmrelease.yaml`:
```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <repo-name>
  namespace: flux-system
spec:
  interval: 24h
  url: <chart-repo-url>        # add to apps/helm-repos.yaml if shared
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app>
  namespace: <app>
  labels:
    app.kubernetes.io/name: <app>
    app.kubernetes.io/part-of: <category>
spec:
  interval: 30m
  chart:
    spec:
      chart: <chart>
      version: <pinned-version>
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system
  valuesFrom:
    - kind: ConfigMap
      name: <app>-values
```

## Rules & gotchas

- **Pin the chart version** — do not leave it floating. Query the chart repo for a
  real recent version; don't guess.
- **Image tags:** before pinning any `image.tag`, query the registry (Docker Hub /
  GHCR) for a current tag — never reuse a stale value or guess from memory.
- **Storage class:** default `vulcan-nfs`; use `vulcan-nfs-strict` for
  consistency-sensitive data, `local-path` for low-latency DBs (Postgres, Loki,
  Prometheus). See CLAUDE.md.
- **Secrets:** create with the `seal-secret` skill and add to `resources:`.
- **Reloader:** if the app should restart on secret/config change, add
  `secret.reloader.stakater.com/reload` / `configmap.reloader.stakater.com/reload`.

## Verify

```bash
# Mirror a working sibling in the same category and diff the shape:
ls apps/<category>/*/manifests/ | head
# Once kustomize is installed:
kustomize build apps/<category>/<app>/manifests | kubeconform -ignore-missing-schemas -summary
```

Commit as a single-purpose commit and push; Flux reconciles automatically.
