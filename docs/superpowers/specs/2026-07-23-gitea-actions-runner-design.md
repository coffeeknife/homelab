# Gitea Actions runner (in-cluster) — design

Date: 2026-07-23
Status: approved

## Goal

Retire the docker-compose `gitea/act_runner` on **gallifrey** and run the Gitea
Actions runner inside the k3s cluster via the official `actions` Helm chart,
GitOps-managed by Flux. Single runner, replacing (not augmenting) gallifrey's.

## Chart

- Repo: `https://dl.gitea.com/charts/` (plain HTTPS Helm repo)
- Chart: `actions`, version `0.1.2` (released 2026-07-21)
- Deploys a **StatefulSet** with two containers: the `runner` and a **privileged
  Docker-in-Docker (DinD) sidecar**. DinD is how jobs run without a host docker
  socket (the compose runner bind-mounted `/var/run/docker.sock`, which does not
  exist in-cluster — k3s uses containerd).

## Placement

New app under `apps/infrastructure/gitea-actions/` (CI plumbing, same tier as
reloader / sealed-secrets), namespace `gitea-actions`.

```
apps/infrastructure/gitea-actions/
  gitea-actions.yaml     # Flux Kustomization CR
  manifests/
    namespace.yaml
    helmrelease.yaml     # chart actions 0.1.2, sourceRef -> gitea-charts HelmRepository
    values.yaml          # externalized ConfigMap via valuesFrom
    secrets.yaml         # SealedSecret: runner-token
    kustomization.yaml   # configMapGenerator, disableNameSuffixHash: true
```

New `HelmRepository` `gitea-charts` (`https://dl.gitea.com/charts/`) added to
`apps/helm-repos.yaml`.

## Key values

- `enabled: true`
- `giteaRootURL: http://192.168.200.52:3000` — internal, verified reachable
  (Gitea LXC on the 200 network; k3s node is .2. Gitea 1.25.4 on :3000).
- `existingSecret: runner-token`, `existingSecretKey: runner-token`
- `global.storageClass: local-path` — node-local, low-latency; the chart exposes
  no per-PVC storageClassName, only this global override. NFS is wrong for the
  runner/DinD scratch volume.
- `statefulset.persistence.size: 2Gi`
- Runner **labels** (carried over from gallifrey so existing workflows still
  match), set inside `statefulset.runner.config`:
  - `ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest-slim`
  - `ubuntu-22.04:docker://docker.gitea.com/runner-images:ubuntu-22.04-slim`
  - `ubuntu-20.04:docker://docker.gitea.com/runner-images:ubuntu-20.04-slim`
- `statefulset.dind.extraArgs: ["--mtu=1400"]` — DinD-over-Flannel-VXLAN fix to
  avoid hung network I/O inside job containers (chart's own suggested workaround).
- Modest resource requests for both containers; DinD gets the larger memory limit.
- Images left at chart defaults (runner `2.0.1`, dind `29.5.2-dind`).

## Secret handling

Site-wide registration token generated in Gitea (Admin → Actions → Runners →
create runner token). Pasted to the assistant, sealed with `kubeseal` into
`secrets.yaml`. No plaintext token in git.

## Cutover (retire gallifrey) — only after in-cluster runner is Idle in Gitea

1. Remove `nixos/hosts/gallifrey/compose/act-runner/` and its import/wiring from
   `nixos/hosts/gallifrey/default.nix`; `colmena apply --on gallifrey --build-on-target`.
2. Delete the old gallifrey runner entry in Gitea admin.
3. Update `CLAUDE.md` (gallifrey no longer runs act-runner).

## Verification

- `flux get hr -n gitea-actions` → Ready
- pod `Running` 2/2 (runner + dind)
- runner shows **Idle** in Gitea admin → Actions → Runners
- a trivial workflow dispatch actually executes and passes
