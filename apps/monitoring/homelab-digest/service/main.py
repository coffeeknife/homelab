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
