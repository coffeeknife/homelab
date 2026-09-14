# Homelab Digest Specialist Model — Design

**Date:** 2026-09-14
**Status:** Draft, pending user review
**Scope:** Fine-tune a small specialist model to compress live k8s/Flux
cluster state into a structured digest, serve it in-cluster on the Intel
HD630, and expose it as a single on-demand HTTP endpoint that an external
Hermes agent calls on its own schedule.

## Problem

Understanding the cluster's current health (pod crashes, Flux reconciliation
failures, node pressure) currently costs a lot of "investigative" tokens when
handed raw to a frontier model — full `kubectl`/Flux output is verbose and
mostly irrelevant. The goal is to interpose a small, cheap, always-on model
that does the raw-data triage/extraction step, so the frontier model doing
the actual reasoning only ever sees a compact structured digest.

The model must run **on the edge** — specifically on hardware already in the
homelab, not a cloud inference API — and specifically on **tau-ceti's Intel
HD630 iGPU**, which is already passed through to `kube-vm`.

## Architecture

```
Hermes (LAN, own schedule)
  │  HTTP request, bearer token
  ▼
apps/monitoring/homelab-digest (new, kube-vm)
  │  1. collect k8s/Flux state (scoped ServiceAccount)
  │  2. POST raw state → Ollama /api/generate, specialist model
  ▼
apps/services/ollama (existing, repaired — Tier 0 of docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md)
  │  runs on HD630 via Vulkan
  ▼
structured JSON digest ──▶ returned as the HTTP response ──▶ Hermes ──▶ frontier model
```

Three components, one of which is mostly already-designed prior art:

1. **Ollama serving fix** — dependency on the existing, approved-but-unimplemented
   Tier 0 remediation in `docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md`.
2. **`apps/monitoring/homelab-digest`** (new) — the collection+inference HTTP
   service.
3. **Training pipeline** (offline, this dev machine) — produces the GGUF that
   Ollama serves.

No CronJob, no push/delivery logic, and no Proxmox/NAS-layer data collection
are part of this design — see Out of Scope.

## Component 1: Ollama serving (dependency, not redesigned here)

`apps/services/ollama/manifests/deployment.yaml` is currently `replicas: 0`
and pinned to retired AMD hardware (`gpu: amd` nodeSelector, `/dev/kfd`
mount, `grinco/ollama-amd-apu:vulkan` image) — this exact defect and its fix
are already fully specified in the Tier 0 section of the 2026-08-02 tiered-LLM
design (image `ollama/ollama:0.32.5`+, `nodeSelector: gpu: intel`, drop
`/dev/kfd`, add memory/CPU limits, `OLLAMA_FLASH_ATTENTION`,
`OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_CONTEXT_LENGTH`, `OLLAMA_MAX_LOADED_MODELS`).
This design **depends on that remediation landing** (or lands it as a
prerequisite step in the implementation plan — the two pieces of work are
independent enough to ship as separate commits) but does not redefine it.

**Addition on top of Tier 0:** the fine-tuned specialist model
(`homelab-digest`, Qwen2.5-1.5B based, ~1 GB at Q4) becomes a second resident
model alongside Tier 0's `qwen2.5-coder:1.5b-base` FIM model. Combined
footprint (~2.2 GB) fits comfortably under the 10Gi limit the Tier 0 design
sets; `OLLAMA_MAX_LOADED_MODELS` may need bumping from 2 to 3 depending on
what else is resident at request time — confirm at implementation time with
`ollama ps`.

Model artifact delivery for v1 is **manual**: GGUF + `Modelfile` copied onto
the existing `ollama-models` PVC (`local-path`) by hand, then
`ollama create homelab-digest -f Modelfile`. No CI/build automation in v1
(see Out of Scope).

## Component 2: `apps/monitoring/homelab-digest`

New app, following the repo's per-app convention
(`apps/monitoring/homelab-digest/manifests/`), plain Kubernetes manifests
(no Helm chart — matches the `ollama` app's own pattern for a small bespoke
service).

**Behavior:** single endpoint, e.g. `POST /digest`. On each request:

1. Collect current cluster state via the Kubernetes API:
   - Pods across all namespaces (phase, restart counts, container statuses)
   - Recent Warning-type Events
   - Node conditions and resource pressure
   - Flux `Kustomization` / `HelmRelease` status (ready/not-ready, last error)
2. Format the collected state into a prompt.
3. Call Ollama's `/api/generate` (in-cluster `ollama.ollama.svc:11434`) with
   the `homelab-digest` model.
4. Parse and return the model's JSON output as the HTTP response body.

**Example response shape** (the training data's target schema is derived
from this, not the reverse):

```json
{
  "generated_at": "2026-09-14T18:03:00Z",
  "summary_counts": {"pods_total": 84, "pods_unhealthy": 2, "flux_not_ready": 1},
  "anomalies": [
    {"kind": "pod_crashloop", "namespace": "media", "resource": "sonarr", "detail": "5 restarts in 20m, OOMKilled", "severity": "warning"},
    {"kind": "flux_not_ready", "namespace": "nextcloud", "resource": "nextcloud", "detail": "HelmRelease stuck: upgrade retries exhausted", "severity": "critical"}
  ],
  "node_pressure": []
}
```

**RBAC:** dedicated ServiceAccount + ClusterRole, `get`/`list`/`watch` only,
scoped to `pods`, `events`, `nodes`, and the Flux
`kustomizations.kustomize.toolkit.fluxcd.io` /
`helmreleases.helm.toolkit.fluxcd.io` CRDs. No write verbs anywhere.

**Auth:** shared-secret bearer token (sealed `Secret`, checked in-app on
every request). Chosen over routing through Authelia forward-auth because
Hermes is a machine caller on a fixed schedule, not an interactive browser
session — this mirrors the existing pattern of carving out non-browser API
access (the arr-suite/qBittorrent Authelia bypass rules) rather than
inventing a new auth model.

**Exposure:** normal `Ingress`, no `cert-manager.io/cluster-issuer`
annotation and no `tls:` block — consistent with every other in-cluster
`Ingress` since the 2026-09-10 traefik-external migration (TLS terminates on
traefik-lxc). Reachable from Hermes over the LAN through the existing
external Traefik path.

**Implementation language:** Python (FastAPI) — simplest path to both a
Kubernetes client library and an HTTP server; no existing constraint in this
repo favors anything else for a bespoke service.

**Image build (v1):** manual `docker build` + `docker push` to an existing
registry (Gitea's own, since it's already running and this repo already
depends on it), deployment references the fixed tag. CI via `gitea-actions`
is an explicit fast-follow, out of scope here.

## Component 3: Training pipeline (offline, this dev machine)

Runs on this dev machine (GTX 1070 Ti, 8GB VRAM / 31GB system RAM) — not
part of the cluster, not part of Flux, not scheduled.

- **Base model:** Qwen2.5-1.5B-Instruct. Small enough for fast HD630
  inference, strong JSON/instruction adherence for its size, permissive
  license. Fallback: Llama-3.2-3B-Instruct if 1.5B proves too weak at the
  extraction task (at the cost of slower inference and a bigger resident
  footprint against the Ollama memory budget above).
- **Method:** QLoRA (4-bit), via Unsloth — fits comfortably in 8GB VRAM,
  fast on consumer hardware at this model size.
- **Training data:** synthetic (raw cluster-state dump → structured JSON
  digest matching the schema above) pairs, labeled by a frontier model.
  Seed scenarios from this homelab's actual documented incidents (Flannel
  `subnet.env`, the Authelia forward-auth bypass saga, NFS/SMR disk
  thrashing symptoms, the ConBee stale-bind failure, Jellyfin's 7-day
  `gpu=amd`/`gpu=intel` mismatch) so the model has seen real failure shapes,
  then generate synthetic variations to cover states not yet hit in practice
  (OOMKilled, PVC pressure, cert expiry, node `NotReady`). Target: a few
  hundred examples — this is a narrow extraction task, not open-ended
  generation, so it doesn't need large-N labeling.
- **Output:** merge LoRA into the base, convert to GGUF (`Q4_K_M`), pair with
  a `Modelfile` defining the system prompt / expected output format. Copied
  onto the `ollama-models` PVC by hand (see Component 1).

## Validation

- **Held-out eval set:** ~15-20% of synthetic pairs excluded from training;
  score the fine-tuned model's digest against the expected one on
  field/anomaly match, not exact text.
- **Real spot checks:** before calling v1 done, run the model against actual
  current cluster snapshots (not synthetic) and manually judge whether the
  digest is something worth handing to Hermes/the frontier model — catches
  what synthetic data doesn't cover.
- **Service-level:** `curl -H "Authorization: Bearer <token>" -X POST
  https://digest.wrenspace.dev/digest` returns a well-formed digest within a
  reasonable latency bound (TBD at implementation time, once HD630 inference
  speed for this model is measured).

## Open items

- Exact ingress hostname for `homelab-digest`.
- Hermes-side integration details (what it does with the digest, its own
  scheduling config) — owned by the user on the Hermes side, not this repo.
- `OLLAMA_MAX_LOADED_MODELS` value once both models' real concurrent
  residency is confirmed.
- Registry target for the manually-built image (Gitea's registry is the
  assumption; confirm it's actually set up for arbitrary image pushes before
  implementation).

## Out of scope

- Proxmox/LXC/NAS-layer monitoring data (v1 is Kubernetes-cluster-only).
- CronJob-based scheduling or any push/delivery logic — Hermes owns
  scheduling and pulls on-demand.
- CI/CD build pipeline for the `homelab-digest` image — fast-follow.
- Any change to Tiers 1-2 of the existing tiered-LLM design (gaming-PC wake
  proxies) — unrelated to this work.
- Training-time use of cloud/rented GPUs — this dev machine's 1070 Ti is
  sufficient for QLoRA at this model size.

## Rollback

Component 2 (`homelab-digest`) is fully additive — a new app, new namespace,
new Ingress. Removing it removes the entire deletion surface; nothing else
depends on it. Component 1 (Ollama fix) rollback is already covered by the
2026-08-02 design (single-file revert, model PVC untouched).
