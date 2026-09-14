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
