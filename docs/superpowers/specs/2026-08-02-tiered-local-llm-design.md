# Tiered Local LLM Serving — Design

**Date:** 2026-08-02
**Status:** Approved design, pending implementation plan
**Scope:** Repair the existing in-cluster ollama deployment, then add two
wake-on-LAN GPU hosts as on-demand inference tiers behind a single endpoint.

## Problem

The homelab runs ollama in-cluster (`apps/services/ollama/`), but the
deployment is broken in three ways and serves models far below what the
available hardware can support. Separately, the intended workloads — editor
autocomplete, CI/batch jobs, agentic coding, and OpenClaw — have requirements
that no single model or host can satisfy.

### Current deployment defects

1. **Pinned to hardware that no longer exists.** `deployment.yaml` sets
   `nodeSelector: gpu: amd`, but `kube-vm` is labeled `gpu=intel` (changed in
   `e054498`, 2026-07-30) after the AMD RX560 retired with etheirys.
   `nodeSelector` is evaluated only at scheduling, so the running pod survives;
   the next restart or node reboot leaves it permanently `Pending`. This is the
   same failure that left Jellyfin unschedulable for seven days.
2. **Wrong image.** `grinco/ollama-amd-apu:vulkan` is a community fork
   targeting AMD Polaris/gfx803. It has no Intel code path and no
   `vulkaninfo` binary. `/dev/dri/renderD128` (the Intel HD630) is visible
   inside the pod but unused — inference is running CPU-only.
3. **No memory limit.** The container declares `requests` only. Cluster memory
   *limits* already sum to 99% of allocatable; an unbounded ollama is a live
   OOM risk (cf. the ntfy OOM cascade, 2026-07-30).

The pinned version is `0.12.5`. Upstream ollama gained Vulkan support in
`0.12.6`, enabled by default — so the deployment sits one release short of the
feature that would light up the HD630, and twenty minor versions behind
current (`0.32.5`, 2026-07-27).

## Measured constraints

All figures measured 2026-08-02, not estimated.

| Host | Total RAM | Actually free | GPU |
|---|---|---|---|
| tau-ceti (hypervisor) | 31 GB | **2 GB** — fully committed to guests | HD630 (passed to kube-vm) |
| kube-vm (k3s node) | 25 GB | ~12–13 GB | HD630 via `renderD128` |
| amphoreus (hypervisor) | 16 GB (2×8, max 32, both slots full) | ~8 GB | HD630, unused |
| Gaming PC A | 32 GB | — | GTX 1070 Ti, 8 GB GDDR5, ~256 GB/s, CUDA |
| Gaming PC B | 16 GB | — | Intel Arc A750, 8 GB GDDR6, ~512 GB/s |

Cluster resource allocation on `kube-vm`: CPU requests 3510m (87%), memory
requests 14968Mi (57%), **memory limits 26034Mi (99%)**. Disk is not a
constraint — 141 GB free on `/`.

Both gaming PCs run **Debian**, sit on the **untagged home LAN**
(192.168.1.0/24), and can be **suspended** rather than powered off.

### Why the HD630 alone is insufficient

Token generation is memory-bandwidth-bound. The HD630 is a UMA iGPU sharing
the same ~34 GB/s DDR4 as the CPU, so it offers little generation speedup. It
*does* help prompt processing, which is compute-bound and parallel — relevant
because coding workloads push large contexts. But at 8–15× less bandwidth than
either discrete GPU, it cannot be the primary inference target.

### Why OpenClaw does not fit in-cluster

OpenClaw requires function calling and **≥64K context**, with community
consensus placing reliable multi-step tool use at **30B+ parameters / ~24 GB**.
Against ~12 GB free on `kube-vm`, this does not fit under any quantization.

## Relationship to per-layer embeddings (PLE)

This work was prompted by coverage of Gemma 3n's PLE technique running a small
model on an ESP32. Two clarifications shaped the design:

- **PLE is an architectural property trained into Gemma 3n/4, not a
  configuration option.** It cannot be applied to arbitrary models. You obtain
  it by running `gemma3n:e2b`/`e4b`, nothing else.
- **Its benefit is specific to scarce discrete VRAM.** On a UMA iGPU,
  offloading embeddings "off the accelerator" moves them from system RAM to
  system RAM. The premise largely evaporates on an HD630.

The *generalizable* principle — stratify parameter residency by access
frequency, keeping hot compute on the fast device and parking cold/sparse
weights in slower memory — is real, and this design applies it via **MoE
expert offload** on Tier 2 (see below). `gemma3n:e4b` is included as an
optional Tier 1 model so the original technique can be benchmarked directly on
owned hardware.

## Architecture

```
clients (Continue.dev, OpenClaw, Claude Code, CI, open-webui)
  │
  └─→ Traefik
        ├─ fim.ai.wrenspace.dev  → in-cluster ollama (HD630)   Tier 0, always on
        ├─ fast.ai.wrenspace.dev → wake-proxy-a750 → PC B      Tier 1, WoL
        └─ big.ai.wrenspace.dev  → wake-proxy-1070 → PC A      Tier 2, WoL
```

**Routing is host-based, one hostname per tier.** Routing on the requested
*model name* would be more ergonomic but is not possible: the model is in the
JSON request body, and Traefik cannot route on body content. Each client is
therefore configured against the tier it needs. Clients never manage wake
state — the proxy does.

| Tier | Host | Model | Serves | Availability |
|---|---|---|---|---|
| 0 | kube-vm / HD630 | `qwen2.5-coder:1.5b-base` | FIM autocomplete | Always on |
| 1 | Arc A750 (16 GB) | `qwen3:8b` Q4 (~5.2 GB), VRAM-resident | Interactive chat, fast agentic | WoL |
| 2 | 1070 Ti (32 GB) | `qwen3-coder:30b-a3b-q4_K_M`, expert offload | OpenClaw, heavy agentic, CI batch | WoL |

### Tiering rationale

The split is driven by **wake latency**, not raw capability. Editor
autocomplete breaks if it waits for a machine to wake, so one small model must
stay permanently resident in-cluster. Every other workload tolerates a wake.

Tier 2 gets the 1070 Ti specifically because that box has **32 GB of system
RAM**. `qwen3-coder:30b-a3b-q4_K_M` is 19 GB — too large for 8 GB of VRAM, but
it is an MoE with only **3B active parameters per token**. Keeping attention
and hot layers in VRAM while parking sparse expert weights in system RAM makes
it viable. The A750 box's 16 GB cannot hold those experts. CUDA is also
ollama's most mature backend, which matters most on the fiddliest
configuration.

Tier 1 gets the A750 for its **512 GB/s** bandwidth (vs the 1070 Ti's 256
GB/s), making it the faster host for any model that fits entirely in 8 GB of
VRAM. That ceiling is real and constrains model choice: an 8B at Q4 (~5.2 GB)
fits with room for KV cache, and `gemma3n:e4b` (~7.5 GB) fits as the optional
PLE benchmark, but a **14B at Q4 is ~9 GB and does not fit** — it would spill
to system RAM and lose the bandwidth advantage that justifies this tier. 14B
belongs on Tier 2 or nowhere.

## Component: Tier 0 remediation

Changes to `apps/services/ollama/manifests/deployment.yaml`:

| Field | From | To | Reason |
|---|---|---|---|
| `image` | `grinco/ollama-amd-apu:vulkan` | `ollama/ollama:0.32.5` | Upstream; Vulkan on by default; Intel path exists |
| `nodeSelector` | `gpu: amd` | `gpu: intel` | Node is labeled `gpu=intel` |
| `resources.limits.memory` | *(absent)* | `10Gi` | Bound an unbounded container |
| `resources.limits.cpu` | *(absent)* | `3500m` | Allow burst without starving the node |
| `env: OLLAMA_VULKAN` | `"true"` | *(removed)* | Fork-specific; upstream enables Vulkan by default |

New environment variables:

- `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_KV_CACHE_TYPE=q8_0` — halves KV cache memory, the practical
  memory-reduction lever available on this tier
- `OLLAMA_CONTEXT_LENGTH=16384` — the 4096 default is unusable for code
- `OLLAMA_MAX_LOADED_MODELS=2`
- `OLLAMA_KEEP_ALIVE=30m` *(retained)*

Memory budget under the 10Gi limit: `qwen2.5-coder:1.5b-base` (~1.1 GB)
resident alongside an 8B Q4 (~5.2 GB) fits with headroom; a 14B Q4 (~9 GB)
fits alone.

**Model note:** FIM requires the `-base` variant. Instruct-tuned checkpoints
are not fill-in-the-middle trained and will produce chat responses where
completions are expected.

Unchanged: PVC (`local-path`, 100Gi — correctly node-local, avoiding the
birdpool SMR NFS path), Service, Ingress, open-webui.

**Optional, flagged:** the container runs `privileged: true`. Since
`renderD128` is mode `0666` inside the pod, `supplementalGroups` alone should
suffice. Worth attempting, with immediate rollback if Vulkan device detection
fails.

Tier 0 ships **independently and first**. It is remediation of an actively
broken, unbounded deployment and is worth landing regardless of whether Tiers
1–2 are ever built.

## Component: wake emitter (tau-ceti)

WoL magic packets are link-layer broadcasts and **do not cross VLANs**. The
cluster is on VLAN 4 (192.168.200.0/24); the gaming PCs are on the untagged
home LAN. An in-cluster pod therefore cannot wake them directly, and consumer
routers generally block directed broadcast.

**tau-ceti hosts the emitter.** It holds `192.168.1.119` on `vmbr2` (untagged
home) and can broadcast to the gaming PCs directly.

Selection rationale: tau-ceti *is* the cluster's hypervisor. If it is down,
there is no wake-proxy pod running to call it, so the emitter introduces
**zero new failure surface**. amphoreus (`192.168.1.31` on `vmbr0`) is also on
the home LAN and would work, but can fail while the cluster still partly runs
— a looser coupling. gallifrey was considered and rejected: it is an
independent host, so using it would add a dependency that can fail on its own,
for no benefit.

Implementation: a minimal HTTP listener (systemd socket-activated unit)
accepting a MAC address and shelling out to `etherwake -i vmbr2 <MAC>`.

**Accepted cost:** Proxmox host configuration is not managed by this repo,
unlike gallifrey's colmena-managed NixOS. tau-ceti was rebuilt from scratch on
2026-07-18, so hand-configuration genuinely risks being lost in a future
rebuild. Mitigation: the emitter setup is documented in `docs/` alongside the
existing runbooks, and the unit file is committed under `proxmox/`.

## Component: wake-proxy (in-cluster)

A small Go service, one instance per WoL box. This is the only net-new
software in the design.

1. Request arrives → health-check upstream ollama
2. Healthy → reverse-proxy through
3. Down → POST the tau-ceti emitter, poll upstream until healthy (cap **20s**),
   then proxy
4. Cap exceeded → `503` with `Retry-After`
5. Idle N minutes → instruct the box to suspend

The 20s cap (rather than 60–90s) is possible because the boxes **suspend
rather than power off** — wake is ~3–5s.

Sablier was considered and rejected: it targets container/deployment
lifecycle, not physical hosts.

**Client note:** OpenClaw must be pointed at ollama's native `/api/chat`
endpoint, **not** the `/v1` OpenAI-compatible one, whose streaming
implementation does not correctly emit `tool_calls` delta chunks.

## Component: exposure

Follows the existing external-ingress pattern verbatim — the same shape as
`apps/external-ingress/manifests/vaultwarden.yaml`: headless `Service` +
hard-coded `Endpoints` + `Ingress` with `cert-manager.io/cluster-issuer:
cert-issuer` and the `websecure` entrypoint. Authelia forward-auth on the
WebUI path.

Keeping the gaming PCs **outside** the cluster is deliberate: a k3s node that
sleeps generates persistent `NotReady` churn, failed evictions, and etcd
noise. It also preserves the single-node decision made when gallifrey was
removed from k3s on 2026-07-08.

## Resulting dependency chain

```
client → Traefik → wake-proxy (k8s) → tau-ceti emitter → magic packet → gaming PC
```

Every hop except the last is something the cluster already depends on.

## Workload coverage

| Workload | Tier | Notes |
|---|---|---|
| Editor FIM autocomplete | 0 | No cold start; `-base` model required |
| Chat over code (open-webui) | 1 | ~40–60 tok/s expected on 8B Q4 |
| Agentic coder (Aider, Cline, Claude Code) | 1 or 2 | 2 for reliable multi-step tool use |
| Scripts / CI / batch | 2 | Latency-tolerant; wake cost amortized |
| OpenClaw | 2 | Requires 64K context + native `/api/chat` |

## Open items

To be filled at implementation time:

- `<PC_A_IP>`, `<PC_A_MAC>` — 1070 Ti box (Tier 2)
- `<PC_B_IP>`, `<PC_B_MAC>` — Arc A750 box (Tier 1)
- Idle-suspend timeout value for the wake-proxy
- A750 backend choice: ollama's Vulkan path vs oneAPI/IPEX-LLM — decide by
  benchmark, not in advance

## Verification

Tier 0:

- `kubectl logs -n ollama deploy/ollama` shows Vulkan device detection naming
  the Intel HD630, not a CPU-only fallback
- `kubectl get pod -n ollama -o wide` confirms scheduling after a deliberate
  `rollout restart` (proves the `nodeSelector` fix)
- Prompt-processing throughput measured before/after to confirm the iGPU is
  actually engaged
- Jellyfin transcode still succeeds with an inference in flight (shared GPU
  contention was accepted, Jellyfin prioritized)

Tiers 1–2:

- Cold-start path: request against a suspended box returns a valid completion
  within the 20s cap
- Timeout path: unreachable box returns `503` with `Retry-After`, not a hang
- `qwen3-coder:30b-a3b` loads with 64K context and completes a multi-step tool
  call via `/api/chat`

## Rollback

Tier 0 is a single-file revert (`git revert`, Flux reconciles). The model PVC
is untouched by the change, so no data is at risk. Tiers 1–2 are additive —
removing the external-ingress manifests and wake-proxy restores the current
state exactly.

## Out of scope

- Adding RAM to amphoreus and making it an inference node — evaluated
  (~$40 for 2×16 GB, slots confirmed upgradeable to 32 GB) and set aside once
  the discrete GPUs entered the picture
- Joining the gaming PCs to k3s
- Cloud API fallback for the agentic tier
- Shrinking kube-vm's memory allocation to free host RAM on tau-ceti
