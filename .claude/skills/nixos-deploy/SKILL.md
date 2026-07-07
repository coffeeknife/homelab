---
name: nixos-deploy
description: Use when deploying NixOS config changes to the homelab cluster nodes with colmena — runs the safe pre-flight (build/eval before push), applies to all nodes or one via --on, and verifies the post-boot k3s flannel quirk. Triggers include "deploy nixos", "colmena apply", "push the nixos changes", "apply node config".
disable-model-invocation: true
---

# Deploy NixOS Changes (colmena)

## Overview

The k3s cluster nodes are managed as NixOS via colmena from `nixos/`. `colmena apply`
builds each host's config and activates it over SSH. A broken eval or a bad k3s/network
change can strand a node, so **always build before you apply**.

Nodes in the hive: `kube-vm` (k3s server, 192.168.200.2), `gallifrey` (arm64 worker Pi),
`vulcan` (NAS). See `CLAUDE.md` for roles.

## Prerequisites

`colmena` lives in `~/.nix-profile/bin`, which `~/.bashrc` only adds for interactive
shells. If `colmena: command not found`:

```bash
export PATH="$HOME/.nix-profile/bin:$PATH"
```

Run all commands from the `nixos/` directory.

## 1. Pre-flight — build without deploying

Evaluate and build every host first. This catches typos in option names, missing
imports, and bad module refs **before** anything touches a live node.

```bash
cd nixos
colmena build            # all hosts; fails loudly on any eval error
```

For a single node: `colmena build --on kube-vm`.

## 2. Apply

Deploy only after the build is clean.

```bash
colmena apply                 # all nodes
colmena apply --on kube-vm    # single node (safest — blast radius of one)
colmena apply --on gallifrey  # the arm64 Pi worker
```

Prefer `--on <node>` when the change is host-specific. `colmena apply` defaults to the
`switch` goal (activate now + on boot). Use `--reboot` only when the change needs it
(kernel, initrd, fileSystems, GPU passthrough) — colmena won't reboot on its own.

## 3. Verify (critical for k3s nodes after a reboot)

`/run/flannel/subnet.env` lives on tmpfs and must exist or pods hang in
`ContainerCreating`. A `systemd.tmpfiles` rule in `modules/k3s-server.nix` recreates
`/run/flannel` at boot — verify it landed:

```bash
ssh kube-vm "ls /run/flannel/subnet.env && systemctl is-active k3s"
```

If the file is missing: `ssh kube-vm "sudo systemctl restart k3s"`.

Then confirm the cluster is healthy from the dev machine (kubectl is configured locally):

```bash
kubectl get nodes            # all Ready
kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck
```

## Secrets

Secrets are sops+age encrypted in `nixos/secrets/*.yaml` and decrypted on the node by
sops-nix at activation. **Never** edit them by hand — use `sops nixos/secrets/secrets.yaml`
(the `sops-plaintext-guard` hook will stop a direct plaintext write). If a deploy fails to
decrypt a secret, confirm the node's age key is a recipient in `nixos/secrets/.sops.yaml`.

## Common mistakes

- **Applying before building** — skip step 1 and an eval error aborts mid-activation.
- **`colmena` not found** — the PATH export above; the non-interactive shell drops it.
- **Forgetting `--reboot`** for kernel/initrd/fileSystems changes — activated but not live
  until the next boot.
- **Node stuck after reboot** — almost always the flannel `subnet.env` quirk; see step 3.

See also: `nixos-reviewer` agent for reviewing the change before you deploy it.
