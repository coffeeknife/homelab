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
