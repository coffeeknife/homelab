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
