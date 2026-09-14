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
