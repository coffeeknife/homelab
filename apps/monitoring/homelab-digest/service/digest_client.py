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
