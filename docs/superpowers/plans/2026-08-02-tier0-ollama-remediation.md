# Tier 0 — In-Cluster Ollama Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the broken in-cluster ollama Deployment so it runs upstream ollama on the Intel HD630, is memory-bounded, survives a restart, and serves a fill-in-the-middle model for editor autocomplete.

**Architecture:** A single-file change to `apps/services/ollama/manifests/deployment.yaml`, reconciled by Flux from `main`. No new resources, no new patterns, no data migration — the model PVC is untouched throughout. Verification is done with `kubectl` assertions against the live cluster, since this repo has no manifest unit-test harness.

**Tech Stack:** Flux CD, Kustomize (via `kubectl kustomize`), kubeconform, ollama 0.32.5, Vulkan/Mesa on Intel HD630.

**Spec:** `docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md`

## Global Constraints

- Image MUST be pinned to `ollama/ollama:0.32.5` — never `:latest`. Repo rule: query the registry before pinning; this tag was verified on Docker Hub as the current release (published 2026-07-27).
- Node label is `gpu=intel`. Never `gpu=amd` — the RX560 retired with etheirys.
- Memory limit `10Gi`, CPU limit `3500m`. The node's memory *limits* already sum to 99% of allocatable; an unbounded container here is an OOM risk.
- `OLLAMA_CONTEXT_LENGTH=16384`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KEEP_ALIVE=30m`.
- FIM model MUST be a `-base` variant. Instruct-tuned checkpoints are not fill-in-the-middle trained.
- Jellyfin has priority on the HD630. Shared-GPU contention was accepted deliberately; if a conflict is found, Jellyfin wins.
- All resources carry `app.kubernetes.io/name` and `app.kubernetes.io/part-of` per the repo labeling standard.
- Commit and push to `main` immediately after each commit. Flux reconciles the homelab kustomization every 5m; use `flux reconcile` to force.

## Discovered Constraints (found during planning, not in the spec)

These were measured on `kube-vm` on 2026-08-02 and change what the manifest should say:

1. **`supplementalGroups` in the current manifest are wrong for this node.** It declares `44` (video) and `110` (render). The actual GIDs on kube-vm are **`video=26`** and **`render=303`**. Neither current value matches anything. The pod works today only because `renderD128` is mode `crw-rw-rw-` (0666, world-accessible) *and* `privileged: true` bypasses permissions entirely.
2. **`/dev/kfd` does not exist on kube-vm as a device.** It is an empty *directory*, auto-created by kubelet because the manifest hostPath-mounts it with no `type`. `/dev/kfd` is the AMD ROCm compute interface and is meaningless on Intel. The mount is dead weight and actively misleading.

Both are corrected in Task 1.

---

### Task 1: Repair the Deployment manifest

**Files:**
- Modify: `apps/services/ollama/manifests/deployment.yaml` (whole file replaced)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a Deployment named `ollama` in namespace `ollama`, selector `app: ollama`, container port `11434` named `http`, backed by PVC `ollama-models`. Task 2 and Task 3 rely on `deploy/ollama` resolving in namespace `ollama`.

- [ ] **Step 1: Capture pre-change evidence**

This is the baseline you will compare against in Task 2. Save it — do not skip, or you cannot prove the GPU change did anything.

```bash
mkdir -p /tmp/ollama-remediation
kubectl get pod -n ollama -l app=ollama -o wide > /tmp/ollama-remediation/pod-before.txt
kubectl exec -n ollama deploy/ollama -- ollama --version > /tmp/ollama-remediation/version-before.txt 2>&1
cat /tmp/ollama-remediation/version-before.txt
```

Expected: `ollama version is 0.12.5-27-g75d17fc`

- [ ] **Step 2: Measure baseline prompt-processing throughput**

The whole point of engaging the iGPU is prefill speed. Without a number now, "it's faster" is unfalsifiable later.

```bash
kubectl exec -n ollama deploy/ollama -- sh -c '
  ollama run qwen2.5-coder:1.5b --verbose "Write a Python function that reverses a linked list." 2>&1 | tail -8
' | tee /tmp/ollama-remediation/bench-before.txt
```

Expected: output includes `prompt eval rate` and `eval rate` lines in tokens/s. Record both numbers.

- [ ] **Step 3: Replace the Deployment manifest**

Replace the entire contents of `apps/services/ollama/manifests/deployment.yaml` with:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ollama
  labels:
    app.kubernetes.io/name: ollama
    app.kubernetes.io/part-of: services
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
        app.kubernetes.io/name: ollama
    spec:
      # kube-vm is labeled gpu=intel (e054498). The AMD RX560 retired with
      # etheirys; the host's integrated HD630 is passed through instead.
      nodeSelector:
        gpu: intel
      securityContext:
        # Actual GIDs on kube-vm: video=26, render=303. The previous values
        # (44, 110) matched no group on this node.
        supplementalGroups:
          - 26   # video
          - 303  # render
      containers:
        - name: ollama
          # Upstream ollama. The Vulkan backend is compiled in and enabled by
          # default since 0.12.6, which is how the Intel HD630 gets used.
          # Previously pinned to grinco/ollama-amd-apu:vulkan, a community
          # fork for AMD Polaris/gfx803 with no Intel code path.
          image: ollama/ollama:0.32.5
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0:11434"
            - name: OLLAMA_MODELS
              value: /root/.ollama/models
            - name: OLLAMA_KEEP_ALIVE
              value: "30m"
            - name: OLLAMA_FLASH_ATTENTION
              value: "1"
            # Halves KV-cache memory. The practical memory lever on a node
            # whose limits already sum to 99% of allocatable.
            - name: OLLAMA_KV_CACHE_TYPE
              value: "q8_0"
            # The 4096 default is unusable for code context.
            - name: OLLAMA_CONTEXT_LENGTH
              value: "16384"
            # Keeps the 1.5B FIM model resident alongside one larger model.
            - name: OLLAMA_MAX_LOADED_MODELS
              value: "2"
          ports:
            - name: http
              containerPort: 11434
          resources:
            requests:
              cpu: 200m
              memory: 2Gi
            limits:
              cpu: 3500m
              memory: 10Gi
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
            - name: dri
              mountPath: /dev/dri
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 60
            periodSeconds: 30
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
        # /dev/kfd (AMD ROCm compute interface) is deliberately NOT mounted.
        # It does not exist on this node; the old hostPath mount caused
        # kubelet to auto-create it as an empty directory.
        - name: dri
          hostPath:
            path: /dev/dri
```

Note what was removed: `securityContext.privileged: true` and the `/dev/kfd` volume + mount. Vulkan compute needs `renderD128`, which is mode 0666 and reachable without privilege.

- [ ] **Step 4: Validate the manifest before it reaches the cluster**

```bash
kubectl kustomize apps/services/ollama/manifests | kubeconform -summary -ignore-missing-schemas
```

Expected: `Summary: 9 resources found parsing stdin - Valid: 9, Invalid: 0, Errors: 0, Skipped: 0`

If Invalid > 0, fix the YAML before proceeding. Do not push a manifest that fails this.

- [ ] **Step 5: Confirm the intended fields actually rendered**

Validation proves the YAML is well-formed, not that it says what you meant. Assert the four critical values:

```bash
kubectl kustomize apps/services/ollama/manifests \
  | python3 -c "
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d['kind'] == 'Deployment' and d['metadata']['name'] == 'ollama':
        s = d['spec']['template']['spec']
        c = s['containers'][0]
        assert s['nodeSelector'] == {'gpu': 'intel'}, s['nodeSelector']
        assert c['image'] == 'ollama/ollama:0.32.5', c['image']
        assert c['resources']['limits']['memory'] == '10Gi', c['resources']
        assert 'privileged' not in c.get('securityContext', {}), 'privileged still set'
        assert all(v['name'] != 'kfd' for v in s['volumes']), 'kfd volume still present'
        print('OK: nodeSelector, image, memory limit, privileged, kfd all correct')
"
```

Expected: `OK: nodeSelector, image, memory limit, privileged, kfd all correct`

- [ ] **Step 6: Commit and push**

```bash
git add apps/services/ollama/manifests/deployment.yaml
git commit -m "fix(ollama): move to upstream 0.32.5 on Intel HD630, bound memory

The deployment was pinned to grinco/ollama-amd-apu:vulkan (an AMD
Polaris fork for the RX560 that retired with etheirys) and to
nodeSelector gpu=amd, while kube-vm is labeled gpu=intel. The pod
survived only because nodeSelector is not re-evaluated for running
pods; any restart would have left it permanently Pending.

Also: correct supplementalGroups to this node's real GIDs (video=26,
render=303, previously 44/110 which matched nothing), drop the
AMD-only /dev/kfd mount, drop privileged (renderD128 is 0666), and
add the memory limit this container never had.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 2: Deploy and prove the Intel GPU is engaged

**Files:**
- No file changes. This task verifies Task 1's deployment against the live cluster.

**Interfaces:**
- Consumes: `deploy/ollama` in namespace `ollama` from Task 1.
- Produces: a confirmed-Running pod on `kube-vm` with Vulkan device detection in its logs. Task 3 requires the pod be Running before pulling models.

- [ ] **Step 1: Force reconciliation**

```bash
flux reconcile kustomization ollama -n flux-system --with-source
```

Expected: `► annotating Kustomization` … `✔ applied revision main@sha1:<hash>`

If the kustomization name is not found, list them: `flux get kustomizations -A`

- [ ] **Step 2: Watch the rollout**

```bash
kubectl rollout status deploy/ollama -n ollama --timeout=300s
```

Expected: `deployment "ollama" successfully rolled out`

Note: `strategy: Recreate` plus a `ReadWriteOnce` PVC means the old pod terminates fully before the new one starts. A 30–60s gap is normal.

**If the pod goes `Pending`:** run `kubectl describe pod -n ollama -l app=ollama` and read the Events. `didn't match Pod's node affinity/selector` means the node label is not `gpu=intel` — check with `kubectl get node kube-vm --show-labels | tr ',' '\n' | grep gpu` before assuming the manifest is wrong.

- [ ] **Step 3: Verify the version actually changed**

```bash
kubectl exec -n ollama deploy/ollama -- ollama --version
```

Expected: `ollama version is 0.32.5`

If this still reports `0.12.5`, the old pod is still serving — re-check Step 2.

- [ ] **Step 4: Assert Vulkan detected the Intel GPU**

This is the load-bearing assertion of the whole task.

```bash
kubectl logs -n ollama deploy/ollama | grep -iE "vulkan|intel|gpu|library|inference compute" | head -20
```

Expected: a line naming a Vulkan device and Intel/HD Graphics 630 — for example `inference compute ... library=vulkan ... name="Intel(R) HD Graphics 630"`.

**Failure mode to watch for:** if the logs say `no compatible GPUs were discovered` or `library=cpu`, the GPU is NOT engaged. Do not proceed to Step 5 — go to Step 6 (rollback of the privilege drop) instead.

- [ ] **Step 5: Re-run the benchmark and compare**

```bash
kubectl exec -n ollama deploy/ollama -- sh -c '
  ollama run qwen2.5-coder:1.5b --verbose "Write a Python function that reverses a linked list." 2>&1 | tail -8
' | tee /tmp/ollama-remediation/bench-after.txt

echo "=== BEFORE ==="; grep -E "eval rate" /tmp/ollama-remediation/bench-before.txt
echo "=== AFTER  ==="; grep -E "eval rate" /tmp/ollama-remediation/bench-after.txt
```

Expected: `prompt eval rate` is materially higher after. Prefill is compute-bound and is where the iGPU helps; `eval rate` (generation) may be roughly unchanged, because the HD630 shares the CPU's ~34 GB/s DDR4 and generation is bandwidth-bound. **An unchanged `eval rate` is not a failure.** A flat `prompt eval rate` is.

- [ ] **Step 6: If and only if Step 4 failed — restore privilege and retry**

Dropping `privileged: true` was the one speculative change in Task 1. If Vulkan found no device, restore it before investigating anything else:

In `apps/services/ollama/manifests/deployment.yaml`, add back under the container, immediately after `image:`:

```yaml
          securityContext:
            privileged: true
```

Then:

```bash
kubectl kustomize apps/services/ollama/manifests | kubeconform -summary -ignore-missing-schemas
git add apps/services/ollama/manifests/deployment.yaml
git commit -m "fix(ollama): restore privileged; renderD128 access insufficient without it

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
flux reconcile kustomization ollama -n flux-system --with-source
kubectl rollout status deploy/ollama -n ollama --timeout=300s
```

Then repeat Step 4. If Vulkan still finds no device with privilege restored, the problem is the image or the passthrough, not permissions — stop and report rather than guessing.

- [ ] **Step 7: Prove the scheduling fix — the restart that would have broken the old manifest**

The original defect was latent: the pod only survived because it was never rescheduled. Prove it is actually fixed.

```bash
kubectl rollout restart deploy/ollama -n ollama
kubectl rollout status deploy/ollama -n ollama --timeout=300s
kubectl get pod -n ollama -l app=ollama -o wide
```

Expected: pod reaches `Running` on node `kube-vm`. Under the old manifest this step is exactly what would have produced a permanently `Pending` pod.

- [ ] **Step 8: Confirm the memory limit is live**

```bash
kubectl get deploy -n ollama ollama -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

Expected: output contains `"limits":{"cpu":"3500m","memory":"10Gi"}`

---

### Task 3: Provision Tier 0 models and verify fill-in-the-middle

**Files:**
- No repo file changes. Models live on the `ollama-models` PVC (`local-path`, 100Gi, node-local — deliberately not the birdpool NFS path).

**Interfaces:**
- Consumes: a Running `deploy/ollama` from Task 2.
- Produces: `qwen2.5-coder:1.5b-base` available for FIM at `http://ollama.ollama.svc.cluster.local:11434`. This is the model Tier 0 serves; the WoL-tier plan assumes it exists and does not re-pull it.

- [ ] **Step 1: Confirm disk headroom before pulling**

```bash
ssh 192.168.200.2 "df -h /"
```

Expected: at least 20 GB available. Measured 141 GB free on 2026-08-02, so this should pass comfortably; it is checked because a failed pull mid-write leaves partial blobs.

- [ ] **Step 2: Pull the FIM base model**

The `-base` suffix is mandatory. `qwen2.5-coder:1.5b` (instruct) will answer FIM prompts conversationally instead of completing code.

```bash
kubectl exec -n ollama deploy/ollama -- ollama pull qwen2.5-coder:1.5b-base
```

Expected: `success`

- [ ] **Step 3: Verify it is a genuine FIM model**

This is the test that distinguishes a working autocomplete backend from a chat model wearing its name. Qwen2.5-Coder FIM uses the sentinel tokens `<|fim_prefix|>`, `<|fim_suffix|>`, `<|fim_middle|>`.

```bash
kubectl exec -n ollama deploy/ollama -- curl -s http://localhost:11434/api/generate -d '{
  "model": "qwen2.5-coder:1.5b-base",
  "prompt": "<|fim_prefix|>def fibonacci(n):\n    if n <= 1:\n        return n\n    return <|fim_suffix|>\n\nprint(fibonacci(10))<|fim_middle|>",
  "stream": false,
  "options": {"num_predict": 40}
}' | python3 -c "import sys,json; print(repr(json.load(sys.stdin)['response']))"
```

Expected: a bare code completion along the lines of `'fibonacci(n-1) + fibonacci(n-2)'`.

**Failure signal:** if the response is prose — "Sure! Here's a Fibonacci function…" — you pulled the instruct model. Re-check the tag includes `-base`.

- [ ] **Step 4: Pull the general-purpose model**

`qwen3:8b` at Q4 is ~5.2 GB, leaving room under the 10Gi limit for the 1.5B model to stay co-resident with `OLLAMA_MAX_LOADED_MODELS=2`.

```bash
kubectl exec -n ollama deploy/ollama -- ollama pull qwen3:8b
```

Expected: `success`

- [ ] **Step 5: Verify both models stay co-resident without breaching the limit**

```bash
kubectl exec -n ollama deploy/ollama -- sh -c '
  curl -s http://localhost:11434/api/generate -d "{\"model\":\"qwen2.5-coder:1.5b-base\",\"prompt\":\"x=\",\"stream\":false,\"options\":{\"num_predict\":5}}" >/dev/null
  curl -s http://localhost:11434/api/generate -d "{\"model\":\"qwen3:8b\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":5}}" >/dev/null
  ollama ps
'
kubectl top pod -n ollama -l app=ollama
```

Expected: `ollama ps` lists **both** models loaded. `kubectl top` shows memory under 10Gi.

**If only one model is listed,** ollama evicted the other for space — acceptable, but note it, because the Tier 0 promise of instant FIM depends on the 1.5B model staying warm.

- [ ] **Step 6: Confirm no OOMKill occurred**

```bash
kubectl get pod -n ollama -l app=ollama -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}{"\n"}'
kubectl get events -n ollama --field-selector reason=OOMKilling 2>/dev/null | tail -5
```

Expected: restart count unchanged from Task 2 Step 7, and no OOMKilling events. This is the check that the new `10Gi` limit is actually workable rather than merely present.

- [ ] **Step 7: Clean up superseded models**

The old instruct-only models are now redundant and consume PVC space.

```bash
kubectl exec -n ollama deploy/ollama -- ollama list
```

Review the list, then remove the models no longer needed:

```bash
kubectl exec -n ollama deploy/ollama -- ollama rm qwen2.5:3b
kubectl exec -n ollama deploy/ollama -- ollama rm qwen2.5-coder:3b
```

Keep `qwen2.5-coder:1.5b` (the instruct 1.5B) only if you want an A/B reference against the base model; otherwise remove it too. Do not remove `qwen2.5-coder:1.5b-base` or `qwen3:8b`.

---

### Task 4: Verify Jellyfin GPU coexistence and document

**Files:**
- Modify: `CLAUDE.md` (the tau-ceti GPU section)

**Interfaces:**
- Consumes: a working Tier 0 from Task 3.
- Produces: documented, verified shared-GPU behavior. No code interface.

- [ ] **Step 1: Confirm Jellyfin still holds the render node**

Both workloads now share one HD630. Establish that Jellyfin's access is intact before testing contention.

```bash
kubectl exec -n jellyfin deploy/jellyfin -- ls -l /dev/dri/renderD128
```

Expected: the device is listed. If this fails, Jellyfin's own passthrough is broken independently of this work — stop and fix that first, since Jellyfin has priority.

- [ ] **Step 2: Test contention directly**

Start a long inference, and while it runs, confirm Jellyfin's transcode path still works.

```bash
kubectl exec -n ollama deploy/ollama -- sh -c '
  curl -s http://localhost:11434/api/generate -d "{\"model\":\"qwen3:8b\",\"prompt\":\"Write a 500 word essay about databases.\",\"stream\":false}" >/dev/null &
  sleep 2
' &

sleep 3
kubectl exec -n jellyfin deploy/jellyfin -- /usr/lib/jellyfin-ffmpeg/ffmpeg \
  -init_hw_device vaapi=va:/dev/dri/renderD128 -f lavfi -i testsrc=duration=3:size=640x480:rate=30 \
  -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - 2>&1 | tail -5
wait
```

Expected: ffmpeg completes without a device-busy or initialization error. VAAPI (Jellyfin) and Vulkan compute (ollama) use independent engines on the same device and should coexist.

**If ffmpeg fails to initialize VAAPI while inference runs:** the accepted design decision is that Jellyfin wins. Record the failure and add a note to the docs in Step 3 rather than silently accepting degraded transcoding.

- [ ] **Step 3: Update CLAUDE.md**

In the `tau-ceti (7050) — cluster/guest hypervisor` section, replace the bullet beginning `**kube-vm now has Intel HD630 QuickSync passthrough**` with:

```markdown
- **kube-vm now has Intel HD630 QuickSync passthrough** — the AMD RX560 stayed
  with etheirys, but the host's integrated HD630 was subsequently passed through
  (verified 2026-07-30: `card1`, driver `i915`, PCI `8086:5912`, with
  `renderD128` visible inside the Jellyfin container). The node label is
  `gpu=intel`; it lagged at `gpu=amd` for a while, which left Jellyfin
  unschedulable for 7 days. **The HD630 is shared between Jellyfin (VAAPI
  transcode) and ollama (Vulkan compute) as of 2026-08-02** — these use
  independent engines and coexist, but Jellyfin has priority by decision. Node
  GIDs are `video=26`, `render=303`; `renderD128` is mode 0666, so pods reach it
  via `supplementalGroups` without `privileged`. `/dev/kfd` does not exist here
  (AMD/ROCm only) — do not hostPath-mount it, or kubelet silently creates an
  empty directory.
```

- [ ] **Step 4: Commit and push**

```bash
git add CLAUDE.md
git commit -m "docs: record HD630 sharing between Jellyfin and ollama

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

---

## Rollback

Tier 0 is a single-file change with no data migration. The `ollama-models` PVC is never touched by any task, so no models are at risk.

```bash
git revert <commit-sha>
git push origin main
flux reconcile kustomization ollama -n flux-system --with-source
```

Caveat: reverting restores `nodeSelector: gpu: amd`, which will leave the pod `Pending` on the next schedule. A revert is therefore a temporary measure only — the old manifest was never viable on current hardware.

## Definition of Done

- [ ] `ollama --version` reports `0.32.5`
- [ ] Logs show Vulkan detecting the Intel HD630 (not `library=cpu`)
- [ ] `prompt eval rate` measurably improved over the recorded baseline
- [ ] Pod returns to `Running` after a deliberate `rollout restart`
- [ ] Memory limit `10Gi` present and no OOMKill events
- [ ] `qwen2.5-coder:1.5b-base` returns a bare code completion to a FIM-sentinel prompt
- [ ] Jellyfin VAAPI transcode succeeds during an active inference
- [ ] `CLAUDE.md` records the shared-GPU arrangement and the GID/`kfd` gotchas
