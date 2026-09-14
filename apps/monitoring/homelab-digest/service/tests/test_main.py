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
