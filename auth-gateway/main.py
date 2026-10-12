"""
OAuth/JWT auth gateway for an OpenAI-compatible LLM backend.

This is the OAuth 2.0 *resource server*. For every request under /v1/* it:
  1. Requires an `Authorization: Bearer <token>` header.
  2. Validates the token as a JWT issued by your IdP (Keycloak by default):
       - signature verified against the IdP's live JWKS (keys fetched + cached)
       - `aud` must equal JWT_AUDIENCE  (the classic "audience" gotcha)
       - `iss` must equal JWT_ISSUER
       - `exp` / `iat` must be present and valid
       - the token must carry REQUIRED_ROLE in realm_access.roles
  3. Strips the client's token, injects the internal LiteLLM key, and
     streams the response back (so SSE / streaming chat completions work).

An optional shared GATEWAY_SERVICE_TOKEN is accepted as a second path, used
by the bundled web UI in the default wiring. Delete it (unset the env var)
to make the gateway strictly JWT-only. See README "Locking down".

This is reference code — read it before running it in production.
"""
import os
import logging

import httpx
import jwt
from jwt import PyJWKClient
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("auth-gateway")

# ---- configuration (from environment) ----
JWKS_URL      = os.environ["JWKS_URL"]            # IdP certs endpoint (internal is fine)
JWT_ISSUER    = os.environ["JWT_ISSUER"]          # expected `iss` (the PUBLIC issuer string)
JWT_AUDIENCE  = os.environ["JWT_AUDIENCE"]        # expected `aud` (e.g. "llm-api")
REQUIRED_ROLE = os.environ.get("REQUIRED_ROLE", "llm_user")
UPSTREAM_URL  = os.environ["UPSTREAM_URL"].rstrip("/")   # e.g. http://litellm:4000
UPSTREAM_KEY  = os.environ["UPSTREAM_KEY"]        # LiteLLM master key — internal only
SERVICE_TOKEN = os.environ.get("GATEWAY_SERVICE_TOKEN")  # optional trusted static token
ALGORITHMS    = ["RS256"]                          # allowlist — never accept "none"

# PyJWKClient fetches and caches signing keys, matching by `kid`. Lazy: it does
# not hit the network until the first token arrives, so boot order is forgiving.
_jwk_client = PyJWKClient(JWKS_URL, cache_keys=True)

app = FastAPI(title="LLM OAuth Gateway")

_HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
               "te", "trailers", "transfer-encoding", "upgrade"}


def _verify_jwt(token: str) -> dict:
    try:
        signing_key = _jwk_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=ALGORITHMS,
            audience=JWT_AUDIENCE,
            issuer=JWT_ISSUER,
            options={"require": ["exp", "iat"]},
        )
    except Exception as e:  # noqa: BLE001 — surface any validation failure as 401
        raise HTTPException(status_code=401, detail=f"invalid token: {e}")

    roles = (claims.get("realm_access") or {}).get("roles", [])
    if REQUIRED_ROLE not in roles:
        raise HTTPException(status_code=403, detail=f"token missing required role '{REQUIRED_ROLE}'")
    return claims


def _authorize(request: Request) -> dict:
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = auth.split(" ", 1)[1].strip()

    if SERVICE_TOKEN and token == SERVICE_TOKEN:
        return {"sub": "gateway-service-account", "via": "service_token"}
    return _verify_jwt(token)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(path: str, request: Request):
    principal = _authorize(request)          # raises 401/403 on failure
    log.info("authorized %s -> /v1/%s", principal.get("sub"), path)

    body = await request.body()
    url = f"{UPSTREAM_URL}/v1/{path}"

    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in _HOP_BY_HOP
               and k.lower() not in ("authorization", "host", "content-length")}
    headers["authorization"] = f"Bearer {UPSTREAM_KEY}"

    client = httpx.AsyncClient(timeout=None)
    upstream_req = client.build_request(
        request.method, url, headers=headers,
        params=request.query_params, content=body,
    )
    upstream = await client.send(upstream_req, stream=True)

    async def _stream():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    resp_headers = {k: v for k, v in upstream.headers.items()
                    if k.lower() not in _HOP_BY_HOP and k.lower() != "content-length"}
    return StreamingResponse(
        _stream(),
        status_code=upstream.status_code,
        headers=resp_headers,
        media_type=upstream.headers.get("content-type"),
    )


@app.exception_handler(HTTPException)
async def _http_exc(_: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code,
                        content={"error": {"message": exc.detail, "code": exc.status_code}})
