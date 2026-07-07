---
name: seal-secret
description: Use when adding, rotating, or encrypting a Kubernetes Secret in this homelab repo — produces a Bitnami SealedSecret (encrypted, safe to commit) instead of plaintext. Triggers include "seal a secret", "encrypt this password", "add a credential", "kubeseal", or the plaintext-secret guard hook firing.
disable-model-invocation: true
---

# Seal a Secret

## Overview

This repo commits secrets **only** as encrypted Bitnami `SealedSecret` resources.
Never commit a raw `kind: Secret` with inline values. Sealing encrypts the value
with the in-cluster controller's public cert; only that controller can decrypt it,
so the ciphertext is safe in Git.

## Prerequisites

- `kubeseal` and `kubectl` installed, with a kubeconfig that can reach the cluster.
- The sealed-secrets controller (installed by `apps/infrastructure/sealed-secrets`).

**Controller coordinates for this cluster (do not guess these):**

| Flag | Value |
|------|-------|
| `--controller-name` | `sealed-secrets-controller` |
| `--controller-namespace` | `kube-system` |

## Seal a value

`SealedSecret` scope here is **strict** (kubeseal default): the ciphertext is bound
to the exact `name` **and** `namespace` below. If either changes, re-seal.

```bash
kubectl create secret generic <secret-name> -n <target-namespace> \
    --from-literal=<key>=<value> \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --format=yaml \
  > apps/<category>/<app>/manifests/<file>.yaml
```

- Multiple keys: repeat `--from-literal=k=v`, or use `--from-file=k=path`.
- The output is a full `SealedSecret` manifest with `spec.encryptedData` — add it to
  the app's `kustomization.yaml` `resources:` list.

## Rotate / add a key to an existing SealedSecret

Re-run the command above with the new value. To merge one new key into an existing
SealedSecret without re-sealing the others, use `kubeseal --merge-into`:

```bash
kubectl create secret generic <secret-name> -n <target-namespace> \
    --from-literal=<newkey>=<newvalue> --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --merge-into apps/<category>/<app>/manifests/<file>.yaml
```

## Verify before committing

```bash
grep -q 'kind: SealedSecret' apps/<category>/<app>/manifests/<file>.yaml \
  && ! grep -Eq '^[[:space:]]*(data|stringData):' apps/<category>/<app>/manifests/<file>.yaml \
  && echo "OK: encrypted, no plaintext block"
```

## Common mistakes

- **Wrong namespace** in `kubectl create secret` → strict-scope seal won't decrypt in
  the app's namespace. It must match where the app runs.
- **Committing the intermediate plaintext** — always pipe `kubectl ... | kubeseal`; never
  write the `kind: Secret` to disk first. The plaintext-secret guard hook will prompt you.
- **Offline sealing** without the controller cert — if you can't reach the cluster, fetch
  the cert once (`kubeseal --fetch-cert ... > cert.pem`) and seal with `--cert cert.pem`.

See also: `new-app` for scaffolding the app these secrets belong to.
