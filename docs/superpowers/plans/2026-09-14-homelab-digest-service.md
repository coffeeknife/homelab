# Homelab Digest Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the in-cluster Ollama deployment for the Intel HD630, then
stand up a new `homelab-digest` service that collects live k8s/Flux cluster
state and turns it into a structured JSON digest on request, ready for an
external Hermes agent to call on its own schedule.

**Architecture:** A FastAPI service in a new `homelab-digest` namespace
collects pod/event/node/Flux state via a read-only ServiceAccount, POSTs it
to the in-cluster Ollama's `/api/generate`, and returns Ollama's parsed JSON
response as the HTTP response — one endpoint, bearer-token authenticated, no
scheduling or delivery logic on this side.

**Tech Stack:** Python 3.12, FastAPI, `kubernetes` client library, Ollama
(served via the existing `apps/services/ollama` deployment), Kubernetes/Flux,
Sealed Secrets.

**Spec:** `docs/superpowers/specs/2026-09-14-homelab-digest-slm-design.md`
(and its dependency, `docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md`,
Tier 0 section, for the Ollama fix)

## Global Constraints

- RBAC for `homelab-digest` is `get`/`list`/`watch` only — no write verbs —
  scoped to `pods`, `events`, `nodes`, and the Flux
  `kustomizations.kustomize.toolkit.fluxcd.io` /
  `helmreleases.helm.toolkit.fluxcd.io` CRDs.
- Auth on the `/digest` endpoint is a shared bearer token (sealed `Secret`),
  not Authelia forward-auth.
- No `cert-manager.io/cluster-issuer` annotation and no `tls:` block on the
  new `Ingress` — TLS terminates on traefik-lxc, per the 2026-09-10
  traefik-external migration.
- Image build for v1 is manual (`docker build` + `docker push`), no CI —
  target registry `git.wrenspace.dev/wrenspace-lab/homelab-digest`.
- Ollama Tier 0 fix values (from the 2026-08-02 design, Tier 0 section):
  image `ollama/ollama:0.32.5`, `nodeSelector: gpu: intel`, drop the
  `/dev/kfd` mount, `resources.limits.memory: 10Gi`,
  `resources.limits.cpu: 3500m`, env `OLLAMA_FLASH_ATTENTION=1`,
  `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_CONTEXT_LENGTH=16384`,
  `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KEEP_ALIVE=30m`.
- Every new resource carries `app.kubernetes.io/name` and
  `app.kubernetes.io/part-of` labels per the repo's labeling standard
  (`part-of: monitoring` for `homelab-digest` resources).
- `homelab-digest` is stateless — no new PVC.
- The fine-tuned specialist model does not exist yet (separate training
  pipeline, out of scope for this plan) — Task 9 verifies the service
  end-to-end against a generic stand-in model tagged `homelab-digest`.

---

### Task 1: Ollama Tier 0 remediation

**Files:**
- Modify: `apps/services/ollama/manifests/deployment.yaml`
- Modify: `apps/services/ollama/ollama.yaml`

**Interfaces:**
- Produces: a running `ollama` Service reachable in-cluster at
  `http://ollama.ollama.svc.cluster.local:11434`, which Task 6/9 depend on.

This task has no unit tests (it's a manifest fix); verification is a live
`flux reconcile` + `kubectl` check, per the existing Tier 0 design's own
Verification section.

- [ ] **Step 1: Read the current deployment manifest**

```bash
cat apps/services/ollama/manifests/deployment.yaml
```

Confirm it still matches the defects described in
`docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md` (AMD image,
`gpu: amd` nodeSelector, `/dev/kfd` mount, `replicas: 0`, no memory limit)
before editing — if someone already fixed it, skip to Step 3.

- [ ] **Step 2: Apply the Tier 0 fix**

Replace the full `spec.template.spec` container/volume section so the file
reads:

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
      nodeSelector:
        gpu: intel
      securityContext:
        supplementalGroups:
          - 44   # video
          - 110  # render
      containers:
        - name: ollama
          image: ollama/ollama:0.32.5
          securityContext:
            privileged: true
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0:11434"
            - name: OLLAMA_MODELS
              value: /root/.ollama/models
            - name: OLLAMA_KEEP_ALIVE
              value: "30m"
            - name: OLLAMA_FLASH_ATTENTION
              value: "1"
            - name: OLLAMA_KV_CACHE_TYPE
              value: "q8_0"
            - name: OLLAMA_CONTEXT_LENGTH
              value: "16384"
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
        - name: dri
          hostPath:
            path: /dev/dri
```

This is Tier 0 exactly as specified: `ollama/ollama:0.32.5` (Vulkan on by
default), `gpu: intel`, no `/dev/kfd`, `replicas: 1`, memory/CPU limits, the
four new `OLLAMA_*` env vars, `OLLAMA_VULKAN` removed (fork-specific,
unneeded upstream).

**Attempt `securityContext.privileged: true` removal first** if you want to
tighten this further — the Tier 0 design flags `renderD128` as mode `0666`
inside the pod, so `supplementalGroups` alone may suffice. Keep `privileged:
true` as the safe default; only drop it if you're going to verify Vulkan
device detection still works (Step 5) and are prepared to revert.

- [ ] **Step 3: Un-suspend the Flux Kustomization**

`apps/services/ollama/ollama.yaml` currently has `suspend: true` (set
2026-08-10 to stop the health check timing out on the broken deployment).
Edit it to:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ollama
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: homelab
  path: ./apps/services/ollama/manifests
  prune: true
  wait: true
```

(Drop both the `suspend: true` line and its explanatory comment — the
condition it describes is what this task fixes.)

- [ ] **Step 4: Review and commit**

Run the `flux-manifest-reviewer` agent over the diff (`git diff
apps/services/ollama/`) before committing — it catches GitOps-specific
issues (missing limits, wrong storage class, etc.) that a generic review
misses.

```bash
git add apps/services/ollama/manifests/deployment.yaml apps/services/ollama/ollama.yaml
git commit -m "fix(ollama): repair Tier 0 deployment for Intel HD630

Per docs/superpowers/specs/2026-08-02-tiered-local-llm-design.md: swap the
AMD-pinned image/nodeSelector/device mount for the Intel equivalents, add
resource limits, un-suspend the Kustomization."
git push
```

- [ ] **Step 5: Verify against the live cluster**

```bash
flux reconcile kustomization flux-system
flux reconcile kustomization ollama
kubectl get pod -n ollama -o wide
kubectl logs -n ollama deploy/ollama | grep -i vulkan
```

Expected: the pod schedules onto `kube-vm` (proves the `nodeSelector` fix),
reaches `Running`, and the logs show Vulkan device detection naming the
Intel HD630 — not a CPU-only fallback. If the pod stays `Pending`, check
`kubectl describe pod -n ollama` for a scheduling reason before going
further.

---

### Task 2: `homelab-digest` namespace and RBAC

**Files:**
- Create: `apps/monitoring/homelab-digest/manifests/namespace.yaml`
- Create: `apps/monitoring/homelab-digest/manifests/rbac.yaml`

**Interfaces:**
- Produces: namespace `homelab-digest`, ServiceAccount
  `homelab-digest`/namespace `homelab-digest` — Task 8's Deployment sets
  `serviceAccountName: homelab-digest` to use this.

No code tests — verification is `kubectl apply --dry-run` and, once Task 8
lands the rest of the app, a live RBAC check.

- [ ] **Step 1: Write the namespace manifest**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homelab-digest
  labels:
    name: homelab-digest
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
```

- [ ] **Step 2: Write the RBAC manifest**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: homelab-digest
  namespace: homelab-digest
  labels:
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: homelab-digest-reader
  labels:
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
rules:
  - apiGroups: [""]
    resources: ["pods", "events", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["kustomize.toolkit.fluxcd.io"]
    resources: ["kustomizations"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["helm.toolkit.fluxcd.io"]
    resources: ["helmreleases"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: homelab-digest-reader
  labels:
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: homelab-digest-reader
subjects:
  - kind: ServiceAccount
    name: homelab-digest
    namespace: homelab-digest
```

- [ ] **Step 3: Dry-run validate**

```bash
kubectl apply --dry-run=client -f apps/monitoring/homelab-digest/manifests/namespace.yaml
kubectl apply --dry-run=client -f apps/monitoring/homelab-digest/manifests/rbac.yaml
```

Expected: both report `created (dry run)` with no errors.

- [ ] **Step 4: Commit**

```bash
git add apps/monitoring/homelab-digest/manifests/namespace.yaml apps/monitoring/homelab-digest/manifests/rbac.yaml
git commit -m "feat(homelab-digest): add namespace and read-only RBAC"
```

(Not pushed yet — Task 8 assembles the full `kustomization.yaml` and Flux
`Kustomization` CR before this app is wired up and pushed together.)

---

### Task 3: Auth token secret

**Files:**
- Create: `apps/monitoring/homelab-digest/manifests/secrets.yaml`

**Interfaces:**
- Produces: `Secret` `digest-auth-token` in namespace `homelab-digest`, key
  `token` — Task 8's Deployment reads this via `secretKeyRef` into the
  `DIGEST_AUTH_TOKEN` env var Task 6's `auth.py` checks against.

- [ ] **Step 1: Generate a random token and seal it**

```bash
TOKEN=$(openssl rand -hex 32)
kubectl create secret generic digest-auth-token \
  --namespace homelab-digest \
  --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - -o yaml \
      app.kubernetes.io/name=homelab-digest \
      app.kubernetes.io/part-of=monitoring \
  | kubeseal --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
      --format yaml \
  > apps/monitoring/homelab-digest/manifests/secrets.yaml
```

The `kubectl label --local` stage is required — `kubectl create secret` has
no `--labels` flag, and every resource in this repo carries
`app.kubernetes.io/name`/`app.kubernetes.io/part-of` labels (Global
Constraints). This mirrors the labeled `spec.template.metadata.labels`
pattern already used in
`apps/infrastructure/gitea-actions/manifests/secrets.yaml` — check that
file if the resulting YAML shape looks unfamiliar.

Save `$TOKEN` somewhere outside git (password manager) — it's what you'll
give Hermes to authenticate with. `kubectl create secret --dry-run=client`
needs the `homelab-digest` namespace to exist for `kubeseal` to scope the
seal correctly; Task 2 creates it, but the namespace need not be *applied*
yet for this command — `kubeseal` only needs the namespace name in the
input YAML, not a live namespace.

- [ ] **Step 2: Confirm the output has no plaintext**

```bash
grep -c "token:" apps/monitoring/homelab-digest/manifests/secrets.yaml
cat apps/monitoring/homelab-digest/manifests/secrets.yaml
```

Expected: the file contains `encryptedData`, not a raw `data:` block — visually
confirm there's no base64 of the actual token sitting in plaintext-adjacent
fields (`kubeseal` produces a `SealedSecret`, never plain `Secret` YAML, but
double-check before committing anything to git).

- [ ] **Step 3: Commit**

```bash
git add apps/monitoring/homelab-digest/manifests/secrets.yaml
git commit -m "feat(homelab-digest): seal the digest endpoint auth token"
```

---

### Task 4: Collector module

**Files:**
- Create: `apps/monitoring/homelab-digest/service/collector.py`
- Test: `apps/monitoring/homelab-digest/service/tests/test_collector.py`
- Create: `apps/monitoring/homelab-digest/service/tests/conftest.py`
- Create: `apps/monitoring/homelab-digest/service/requirements.txt`
- Create: `apps/monitoring/homelab-digest/service/requirements-dev.txt`

**Interfaces:**
- Produces: `collect_cluster_state(core_v1: kubernetes.client.CoreV1Api,
  custom_objects: kubernetes.client.CustomObjectsApi) -> dict` — Task 6's
  `main.py` calls this directly by name.

- [ ] **Step 1: Create the requirements files**

`apps/monitoring/homelab-digest/service/requirements.txt`:

```
fastapi==0.115.6
uvicorn[standard]==0.34.0
kubernetes==31.0.0
requests==2.32.3
```

`apps/monitoring/homelab-digest/service/requirements-dev.txt`:

```
-r requirements.txt
pytest==8.3.4
httpx==0.28.1
```

- [ ] **Step 2: Set up the local dev environment**

```bash
cd apps/monitoring/homelab-digest/service
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
```

- [ ] **Step 3: Write `conftest.py` so tests can import the flat modules**

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
```

- [ ] **Step 4: Write the failing test for pod collection**

`apps/monitoring/homelab-digest/service/tests/test_collector.py`:

```python
from unittest.mock import MagicMock

from collector import collect_cluster_state


def _container_status(restart_count=0, waiting_reason=None):
    cs = MagicMock()
    cs.restart_count = restart_count
    if waiting_reason:
        cs.state.waiting.reason = waiting_reason
    else:
        cs.state.waiting = None
    return cs


def _empty_kube_clients():
    core_v1 = MagicMock()
    core_v1.list_pod_for_all_namespaces.return_value.items = []
    core_v1.list_event_for_all_namespaces.return_value.items = []
    core_v1.list_node.return_value.items = []
    custom_objects = MagicMock()
    custom_objects.list_cluster_custom_object.return_value = {"items": []}
    return core_v1, custom_objects


def test_collect_pods_ignores_healthy_pods():
    core_v1, custom_objects = _empty_kube_clients()
    healthy_pod = MagicMock()
    healthy_pod.metadata.namespace = "media"
    healthy_pod.metadata.name = "healthy"
    healthy_pod.status.phase = "Running"
    healthy_pod.status.container_statuses = [_container_status(restart_count=0)]
    core_v1.list_pod_for_all_namespaces.return_value.items = [healthy_pod]

    result = collect_cluster_state(core_v1, custom_objects)

    assert result["pods"] == []


def test_collect_pods_flags_crashlooping_pod():
    core_v1, custom_objects = _empty_kube_clients()
    crashing_pod = MagicMock()
    crashing_pod.metadata.namespace = "media"
    crashing_pod.metadata.name = "sonarr"
    crashing_pod.status.phase = "Running"
    crashing_pod.status.container_statuses = [
        _container_status(restart_count=5, waiting_reason="CrashLoopBackOff")
    ]
    core_v1.list_pod_for_all_namespaces.return_value.items = [crashing_pod]

    result = collect_cluster_state(core_v1, custom_objects)

    assert len(result["pods"]) == 1
    assert result["pods"][0] == {
        "namespace": "media",
        "name": "sonarr",
        "phase": "Running",
        "restart_count": 5,
        "waiting_reasons": ["CrashLoopBackOff"],
    }
```

- [ ] **Step 5: Run it to confirm it fails**

```bash
cd apps/monitoring/homelab-digest/service
python -m pytest tests/test_collector.py -v
```

Expected: `ModuleNotFoundError: No module named 'collector'`.

- [ ] **Step 6: Implement `collector.py`**

```python
from __future__ import annotations

from typing import Any

from kubernetes import client


def collect_cluster_state(
    core_v1: client.CoreV1Api, custom_objects: client.CustomObjectsApi
) -> dict[str, Any]:
    return {
        "pods": _collect_pods(core_v1),
        "warning_events": _collect_warning_events(core_v1),
        "node_pressure": _collect_node_pressure(core_v1),
        "flux": _collect_flux_status(custom_objects),
    }


def _collect_pods(core_v1: client.CoreV1Api) -> list[dict[str, Any]]:
    result = []
    pod_list = core_v1.list_pod_for_all_namespaces(watch=False)
    for pod in pod_list.items:
        restart_count = 0
        waiting_reasons = []
        for cs in pod.status.container_statuses or []:
            restart_count += cs.restart_count
            if cs.state and cs.state.waiting:
                waiting_reasons.append(cs.state.waiting.reason)
        if restart_count == 0 and not waiting_reasons and pod.status.phase in (
            "Running",
            "Succeeded",
        ):
            continue
        result.append(
            {
                "namespace": pod.metadata.namespace,
                "name": pod.metadata.name,
                "phase": pod.status.phase,
                "restart_count": restart_count,
                "waiting_reasons": waiting_reasons,
            }
        )
    return result


def _collect_warning_events(core_v1: client.CoreV1Api) -> list[dict[str, Any]]:
    result = []
    events = core_v1.list_event_for_all_namespaces(
        field_selector="type=Warning", limit=50
    )
    for event in events.items:
        result.append(
            {
                "namespace": event.metadata.namespace,
                "reason": event.reason,
                "message": event.message,
                "involved_object": (
                    event.involved_object.name if event.involved_object else None
                ),
                "count": event.count,
            }
        )
    return result


def _collect_node_pressure(core_v1: client.CoreV1Api) -> list[dict[str, Any]]:
    result = []
    nodes = core_v1.list_node()
    for node in nodes.items:
        bad_conditions = []
        for condition in node.status.conditions or []:
            is_ready = condition.type == "Ready"
            is_bad = (is_ready and condition.status != "True") or (
                not is_ready and condition.status == "True"
            )
            if is_bad:
                bad_conditions.append(
                    {
                        "type": condition.type,
                        "status": condition.status,
                        "reason": condition.reason,
                    }
                )
        if bad_conditions:
            result.append({"name": node.metadata.name, "conditions": bad_conditions})
    return result


def _collect_flux_status(custom_objects: client.CustomObjectsApi) -> dict[str, Any]:
    not_ready = []

    kustomizations = custom_objects.list_cluster_custom_object(
        group="kustomize.toolkit.fluxcd.io", version="v1", plural="kustomizations"
    )
    for item in kustomizations.get("items", []):
        if not _is_ready(item):
            not_ready.append(
                {
                    "kind": "Kustomization",
                    "name": item["metadata"]["name"],
                    "namespace": item["metadata"]["namespace"],
                }
            )

    helmreleases = custom_objects.list_cluster_custom_object(
        group="helm.toolkit.fluxcd.io", version="v2", plural="helmreleases"
    )
    for item in helmreleases.get("items", []):
        if not _is_ready(item):
            not_ready.append(
                {
                    "kind": "HelmRelease",
                    "name": item["metadata"]["name"],
                    "namespace": item["metadata"]["namespace"],
                }
            )

    return {"not_ready": not_ready}


def _is_ready(obj: dict[str, Any]) -> bool:
    for condition in obj.get("status", {}).get("conditions", []):
        if condition.get("type") == "Ready":
            return condition.get("status") == "True"
    return False
```

- [ ] **Step 7: Run the tests again**

```bash
python -m pytest tests/test_collector.py -v
```

Expected: both tests `PASS`.

- [ ] **Step 8: Add and run the Flux status test**

Append to `tests/test_collector.py`:

```python
def test_collect_flux_status_flags_not_ready_kustomization_only():
    core_v1, custom_objects = _empty_kube_clients()
    not_ready_kustomization = {
        "metadata": {"name": "nextcloud", "namespace": "flux-system"},
        "status": {"conditions": [{"type": "Ready", "status": "False"}]},
    }
    ready_helmrelease = {
        "metadata": {"name": "grafana", "namespace": "flux-system"},
        "status": {"conditions": [{"type": "Ready", "status": "True"}]},
    }
    custom_objects.list_cluster_custom_object.side_effect = [
        {"items": [not_ready_kustomization]},
        {"items": [ready_helmrelease]},
    ]

    result = collect_cluster_state(core_v1, custom_objects)

    assert result["flux"]["not_ready"] == [
        {"kind": "Kustomization", "name": "nextcloud", "namespace": "flux-system"}
    ]
```

```bash
python -m pytest tests/test_collector.py -v
```

Expected: all three tests `PASS`.

- [ ] **Step 9: Commit**

```bash
cd /home/robin/Dev/homelab
git add apps/monitoring/homelab-digest/service/collector.py \
  apps/monitoring/homelab-digest/service/tests/test_collector.py \
  apps/monitoring/homelab-digest/service/tests/conftest.py \
  apps/monitoring/homelab-digest/service/requirements.txt \
  apps/monitoring/homelab-digest/service/requirements-dev.txt
git commit -m "feat(homelab-digest): add cluster state collector"
```

---

### Task 5: Digest client module

**Files:**
- Create: `apps/monitoring/homelab-digest/service/digest_client.py`
- Test: `apps/monitoring/homelab-digest/service/tests/test_digest_client.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `generate_digest(raw_state: dict, *, ollama_url: str, model: str,
  timeout: float = 60.0) -> dict` and `DigestGenerationError` (exception
  class) — Task 6's `main.py` calls `generate_digest` directly and may
  choose to catch `DigestGenerationError`.

- [ ] **Step 1: Write the failing tests**

```python
import json
from unittest.mock import MagicMock, patch

import pytest

from digest_client import DigestGenerationError, generate_digest


@patch("digest_client.requests.post")
def test_generate_digest_parses_model_json_output(mock_post):
    mock_response = MagicMock()
    mock_response.json.return_value = {"response": json.dumps({"anomalies": []})}
    mock_response.raise_for_status.return_value = None
    mock_post.return_value = mock_response

    result = generate_digest(
        {"pods": []}, ollama_url="http://ollama:11434", model="homelab-digest"
    )

    assert result == {"anomalies": []}
    call_kwargs = mock_post.call_args.kwargs
    assert call_kwargs["json"]["model"] == "homelab-digest"
    assert call_kwargs["json"]["format"] == "json"


@patch("digest_client.requests.post")
def test_generate_digest_raises_on_non_json_model_output(mock_post):
    mock_response = MagicMock()
    mock_response.json.return_value = {"response": "not json"}
    mock_response.raise_for_status.return_value = None
    mock_post.return_value = mock_response

    with pytest.raises(DigestGenerationError):
        generate_digest(
            {"pods": []}, ollama_url="http://ollama:11434", model="homelab-digest"
        )
```

- [ ] **Step 2: Run to confirm it fails**

```bash
python -m pytest tests/test_digest_client.py -v
```

Expected: `ModuleNotFoundError: No module named 'digest_client'`.

- [ ] **Step 3: Implement `digest_client.py`**

```python
from __future__ import annotations

import json
from typing import Any

import requests


class DigestGenerationError(Exception):
    pass


def generate_digest(
    raw_state: dict[str, Any],
    *,
    ollama_url: str,
    model: str,
    timeout: float = 60.0,
) -> dict[str, Any]:
    prompt = json.dumps(raw_state, separators=(",", ":"))
    response = requests.post(
        f"{ollama_url}/api/generate",
        json={"model": model, "prompt": prompt, "format": "json", "stream": False},
        timeout=timeout,
    )
    response.raise_for_status()
    raw_output = response.json().get("response", "")
    try:
        return json.loads(raw_output)
    except json.JSONDecodeError as exc:
        raise DigestGenerationError(
            f"model returned non-JSON output: {raw_output!r}"
        ) from exc
```

- [ ] **Step 4: Run the tests again**

```bash
python -m pytest tests/test_digest_client.py -v
```

Expected: both tests `PASS`.

- [ ] **Step 5: Commit**

```bash
cd /home/robin/Dev/homelab
git add apps/monitoring/homelab-digest/service/digest_client.py \
  apps/monitoring/homelab-digest/service/tests/test_digest_client.py
git commit -m "feat(homelab-digest): add Ollama digest client"
```

---

### Task 6: FastAPI app with bearer-token auth

**Files:**
- Create: `apps/monitoring/homelab-digest/service/auth.py`
- Create: `apps/monitoring/homelab-digest/service/main.py`
- Test: `apps/monitoring/homelab-digest/service/tests/test_auth.py`
- Test: `apps/monitoring/homelab-digest/service/tests/test_main.py`

**Interfaces:**
- Consumes: `collect_cluster_state` (Task 4), `generate_digest` +
  `DigestGenerationError` (Task 5).
- Produces: FastAPI `app` object with `GET /healthz` (no auth) and `POST
  /digest` (bearer-token auth) — Task 7's Dockerfile runs this as
  `main:app`.

- [ ] **Step 1: Write the failing auth test**

`tests/test_auth.py`:

```python
import os

os.environ["DIGEST_AUTH_TOKEN"] = "test-token"

import pytest
from fastapi import HTTPException

from auth import require_bearer_token


def test_require_bearer_token_rejects_missing_header():
    with pytest.raises(HTTPException) as exc_info:
        require_bearer_token(authorization=None)
    assert exc_info.value.status_code == 401


def test_require_bearer_token_rejects_wrong_token():
    with pytest.raises(HTTPException) as exc_info:
        require_bearer_token(authorization="Bearer wrong-token")
    assert exc_info.value.status_code == 401


def test_require_bearer_token_accepts_correct_token():
    require_bearer_token(authorization="Bearer test-token")
```

- [ ] **Step 2: Run to confirm it fails**

```bash
python -m pytest tests/test_auth.py -v
```

Expected: `ModuleNotFoundError: No module named 'auth'`.

- [ ] **Step 3: Implement `auth.py`**

```python
from __future__ import annotations

import os
import secrets

from fastapi import Header, HTTPException


def require_bearer_token(authorization: str | None = Header(default=None)) -> None:
    expected = os.environ["DIGEST_AUTH_TOKEN"]
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    provided = authorization.removeprefix("Bearer ")
    if not secrets.compare_digest(provided, expected):
        raise HTTPException(status_code=401, detail="invalid bearer token")
```

- [ ] **Step 4: Run the auth tests again**

```bash
python -m pytest tests/test_auth.py -v
```

Expected: all three `PASS`.

- [ ] **Step 5: Write the failing app tests**

`tests/test_main.py`:

```python
import os

os.environ.setdefault("DIGEST_AUTH_TOKEN", "test-token")

from fastapi.testclient import TestClient

import main


def test_healthz_requires_no_auth():
    client = TestClient(main.app)
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_digest_rejects_missing_token():
    client = TestClient(main.app)
    response = client.post("/digest")
    assert response.status_code == 401


def test_digest_returns_generated_digest(monkeypatch):
    monkeypatch.setattr(main, "_load_kube_clients", lambda: (None, None))
    monkeypatch.setattr(
        main,
        "collect_cluster_state",
        lambda core_v1, custom_objects: {"pods": []},
    )
    monkeypatch.setattr(
        main,
        "generate_digest",
        lambda raw_state, ollama_url, model: {"anomalies": []},
    )

    client = TestClient(main.app)
    response = client.post("/digest", headers={"Authorization": "Bearer test-token"})

    assert response.status_code == 200
    assert response.json() == {"anomalies": []}
```

- [ ] **Step 6: Run to confirm it fails**

```bash
python -m pytest tests/test_main.py -v
```

Expected: `ModuleNotFoundError: No module named 'main'`.

- [ ] **Step 7: Implement `main.py`**

```python
from __future__ import annotations

import os

from fastapi import Depends, FastAPI
from kubernetes import client, config

from auth import require_bearer_token
from collector import collect_cluster_state
from digest_client import generate_digest

app = FastAPI()

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama.ollama.svc.cluster.local:11434")
DIGEST_MODEL = os.environ.get("DIGEST_MODEL", "homelab-digest")


def _load_kube_clients() -> tuple[client.CoreV1Api, client.CustomObjectsApi]:
    config.load_incluster_config()
    return client.CoreV1Api(), client.CustomObjectsApi()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/digest")
def digest(_: None = Depends(require_bearer_token)) -> dict:
    core_v1, custom_objects = _load_kube_clients()
    raw_state = collect_cluster_state(core_v1, custom_objects)
    return generate_digest(raw_state, ollama_url=OLLAMA_URL, model=DIGEST_MODEL)
```

- [ ] **Step 8: Run all tests**

```bash
python -m pytest tests/ -v
```

Expected: every test across `test_collector.py`, `test_digest_client.py`,
`test_auth.py`, and `test_main.py` `PASS`.

- [ ] **Step 9: Commit**

```bash
cd /home/robin/Dev/homelab
git add apps/monitoring/homelab-digest/service/auth.py \
  apps/monitoring/homelab-digest/service/main.py \
  apps/monitoring/homelab-digest/service/tests/test_auth.py \
  apps/monitoring/homelab-digest/service/tests/test_main.py
git commit -m "feat(homelab-digest): add FastAPI app with bearer-token auth"
```

---

### Task 7: Dockerfile and manual image build/push

**Files:**
- Create: `apps/monitoring/homelab-digest/service/Dockerfile`
- Create: `apps/monitoring/homelab-digest/service/.dockerignore`

**Interfaces:**
- Produces: image `git.wrenspace.dev/wrenspace-lab/homelab-digest:0.1.0`,
  pushed to the registry — Task 8's Deployment manifest references this
  exact tag.

- [ ] **Step 1: Write `.dockerignore`**

```
.venv/
tests/
__pycache__/
*.pyc
```

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py collector.py digest_client.py auth.py ./

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 3: Build the image locally**

```bash
cd apps/monitoring/homelab-digest/service
docker build -t git.wrenspace.dev/wrenspace-lab/homelab-digest:0.1.0 .
```

Expected: build completes with no errors.

- [ ] **Step 4: Smoke-test the image locally**

```bash
docker run --rm -p 8080:8080 -e DIGEST_AUTH_TOKEN=smoke-test \
  git.wrenspace.dev/wrenspace-lab/homelab-digest:0.1.0 &
sleep 2
curl -s http://localhost:8080/healthz
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/digest
docker stop $(docker ps -q --filter ancestor=git.wrenspace.dev/wrenspace-lab/homelab-digest:0.1.0)
```

Expected: `/healthz` returns `{"status":"ok"}`; `/digest` without a bearer
token returns `401` (it will not reach the Kubernetes API call inside a
plain `docker run`, which is correct — auth is checked first).

- [ ] **Step 5: Log in and push**

```bash
docker login git.wrenspace.dev
docker push git.wrenspace.dev/wrenspace-lab/homelab-digest:0.1.0
```

Expected: push succeeds; confirm the tag is visible under the repo's
package/registry view in the Gitea web UI.

- [ ] **Step 6: Commit the Dockerfile**

```bash
cd /home/robin/Dev/homelab
git add apps/monitoring/homelab-digest/service/Dockerfile apps/monitoring/homelab-digest/service/.dockerignore
git commit -m "feat(homelab-digest): add Dockerfile, build+push 0.1.0 manually"
```

---

### Task 8: Deployment, Service, Ingress, and Flux wiring

**Files:**
- Create: `apps/monitoring/homelab-digest/manifests/deployment.yaml`
- Create: `apps/monitoring/homelab-digest/manifests/service.yaml`
- Create: `apps/monitoring/homelab-digest/manifests/ingress.yaml`
- Create: `apps/monitoring/homelab-digest/manifests/kustomization.yaml`
- Create: `apps/monitoring/homelab-digest/homelab-digest.yaml`

**Interfaces:**
- Consumes: image tag from Task 7, Secret from Task 3, ServiceAccount from
  Task 2.
- Produces: live `Ingress` at `digest.wrenspace.dev`, reachable from the LAN
  — Task 9 verifies against this.

- [ ] **Step 1: Write the Deployment**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homelab-digest
  namespace: homelab-digest
  labels:
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: homelab-digest
  template:
    metadata:
      labels:
        app: homelab-digest
        app.kubernetes.io/name: homelab-digest
    spec:
      serviceAccountName: homelab-digest
      containers:
        - name: homelab-digest
          image: git.wrenspace.dev/wrenspace-lab/homelab-digest:0.1.0
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: OLLAMA_URL
              value: "http://ollama.ollama.svc.cluster.local:11434"
            - name: DIGEST_MODEL
              value: "homelab-digest"
            - name: DIGEST_AUTH_TOKEN
              valueFrom:
                secretKeyRef:
                  name: digest-auth-token
                  key: token
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 15
            periodSeconds: 30
```

- [ ] **Step 2: Write the Service**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: homelab-digest
  namespace: homelab-digest
  labels:
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
spec:
  type: ClusterIP
  selector:
    app: homelab-digest
  ports:
    - name: http
      port: 8080
      targetPort: http
```

- [ ] **Step 3: Write the Ingress**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homelab-digest
  namespace: homelab-digest
  labels:
    app.kubernetes.io/name: homelab-digest
    app.kubernetes.io/part-of: monitoring
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  rules:
    - host: digest.wrenspace.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homelab-digest
                port:
                  name: http
```

- [ ] **Step 4: Write the manifests kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - rbac.yaml
  - secrets.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

- [ ] **Step 5: Write the top-level Flux Kustomization**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: homelab-digest
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: homelab
  path: ./apps/monitoring/homelab-digest/manifests
  prune: true
  wait: true
  dependsOn:
    - name: ollama
```

- [ ] **Step 6: Dry-run the full kustomization**

```bash
kubectl kustomize apps/monitoring/homelab-digest/manifests | kubectl apply --dry-run=client -f -
```

Expected: every resource reports `created (dry run)`, no errors.

- [ ] **Step 7: Review, commit, push**

Run the `flux-manifest-reviewer` agent over
`apps/monitoring/homelab-digest/` before committing.

```bash
cd /home/robin/Dev/homelab
git add apps/monitoring/homelab-digest/manifests/deployment.yaml \
  apps/monitoring/homelab-digest/manifests/service.yaml \
  apps/monitoring/homelab-digest/manifests/ingress.yaml \
  apps/monitoring/homelab-digest/manifests/kustomization.yaml \
  apps/monitoring/homelab-digest/homelab-digest.yaml
git commit -m "feat(homelab-digest): deploy service, wire into Flux"
git push
```

- [ ] **Step 8: Reconcile and check rollout**

```bash
flux reconcile kustomization flux-system
flux reconcile kustomization homelab-digest
kubectl get pod -n homelab-digest -o wide
kubectl logs -n homelab-digest deploy/homelab-digest
```

Expected: pod reaches `Running` and `1/1 Ready`; logs show uvicorn started
with no startup errors.

---

### Task 9: End-to-end verification with a stand-in model

The fine-tuned `homelab-digest` model doesn't exist yet — that's a separate
training-pipeline effort. This task proves the collection→inference→response
plumbing works using any available instruct model as a stand-in, tagged to
match what the service expects.

**Files:** none (verification only).

- [ ] **Step 1: Pull a stand-in model and tag it**

```bash
kubectl exec -n ollama deploy/ollama -- ollama pull qwen2.5:1.5b-instruct
kubectl exec -n ollama deploy/ollama -- sh -c 'cat <<EOF > /tmp/Modelfile
FROM qwen2.5:1.5b-instruct
SYSTEM """You summarize Kubernetes cluster state as compact JSON. Given a
JSON blob of pods, warning_events, node_pressure, and flux status, respond
with ONLY a JSON object of the form
{"generated_at": "...", "summary_counts": {...}, "anomalies": [...], "node_pressure": [...]}.
No prose."""
EOF'
kubectl exec -n ollama deploy/ollama -- ollama create homelab-digest -f /tmp/Modelfile
kubectl exec -n ollama deploy/ollama -- ollama list
```

Expected: `ollama list` shows a `homelab-digest` entry.

- [ ] **Step 2: Call the live endpoint**

```bash
TOKEN=<the token saved in Task 3, Step 1>
curl -s -H "Authorization: Bearer $TOKEN" -X POST https://digest.wrenspace.dev/digest | jq .
```

Expected: HTTP 200, a JSON body roughly matching the shape in the
`SYSTEM` prompt above. Content quality will be mediocre — the stand-in model
is not fine-tuned — but a well-formed, non-error JSON response proves the
collector → Ollama → response path works end-to-end.

- [ ] **Step 3: Confirm auth actually rejects bad tokens against the live service**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer wrong" -X POST https://digest.wrenspace.dev/digest
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://digest.wrenspace.dev/digest
```

Expected: both return `401`.

- [ ] **Step 4: Confirm Jellyfin still works with the shared iGPU**

```bash
# Trigger a transcode (play something in a client that forces transcoding,
# or check Jellyfin's dashboard for an active transcode), then:
kubectl logs -n ollama deploy/ollama --since=5m | grep -i vulkan
```

Expected: Jellyfin transcoding still succeeds with the digest service also
resident on the same HD630 — confirms the shared-GPU contention accepted in
the Tier 0 design holds in practice.

- [ ] **Step 5: Confirm `OLLAMA_MAX_LOADED_MODELS` is sufficient**

```bash
kubectl exec -n ollama deploy/ollama -- ollama ps
```

Expected: both `qwen2.5-coder:1.5b-base` (Tier 0's FIM model, if it has been
loaded elsewhere) and `homelab-digest` can be resident together without one
evicting the other under normal use. If requests start showing reload
latency because the cache keeps thrashing between two models, bump
`OLLAMA_MAX_LOADED_MODELS` from `2` to `3` in
`apps/services/ollama/manifests/deployment.yaml` and re-check the 10Gi
memory limit still holds (both 1.5B Q4 models together are ~2.2 GB, well
under it).

At this point the plumbing is proven. Swapping the stand-in model for the
real fine-tuned one (once trained) is just Step 1 repeated with the real
GGUF/Modelfile — no service code changes needed.
