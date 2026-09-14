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
