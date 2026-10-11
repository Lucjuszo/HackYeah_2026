"""Pure ASGI middlewares: request body size limit and security headers on every response."""

import re

from fastapi import HTTPException
from starlette.datastructures import Headers, MutableHeaders
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.config import settings

# Photo uploads (POST /places/{id}/photos) may be as large as MAX_PHOTO_BYTES plus the multipart envelope.
_UPLOAD_PATH = re.compile(r"^/places/[^/]+/photos/?$")
_MULTIPART_OVERHEAD = 64 * 1024


class _TooLarge(HTTPException):
    """An HTTPException, so FastAPI's body parsing passes it on and the app answers 413 by itself."""

    def __init__(self, limit: int) -> None:
        super().__init__(413, f"Request body too large (max {limit} bytes)")


def body_limit(scope: Scope) -> int:
    if scope["method"] == "POST" and _UPLOAD_PATH.match(scope["path"]):
        return settings.max_photo_bytes + _MULTIPART_OVERHEAD
    return settings.max_request_bytes


class BodySizeLimitMiddleware:
    """413 for request bodies over the limit, before the app parses them.

    Without it Starlette spools a multipart upload of any size to disk (/tmp is a RAM-backed tmpfs
    in deploy/docker-compose.yml) and reads JSON bodies of any size into memory – both before the
    endpoint, and so before authentication, runs. Checks Content-Length up front and counts the
    bytes of chunked bodies as they arrive.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        limit = body_limit(scope)
        declared = Headers(scope=scope).get("content-length")
        if declared is not None:
            try:
                too_large = int(declared) > limit
            except ValueError:
                await JSONResponse({"detail": "Invalid Content-Length"}, 400)(scope, receive, send)
                return
            if too_large:
                await self._reject(scope, receive, send, limit)
                return

        received = 0
        response_started = False

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > limit:
                    raise _TooLarge(limit)
            return message

        async def tracking_send(message: Message) -> None:
            nonlocal response_started
            if message["type"] == "http.response.start":
                response_started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, tracking_send)
        except _TooLarge:
            if response_started:
                raise
            await self._reject(scope, receive, send, limit)

    @staticmethod
    async def _reject(scope: Scope, receive: Receive, send: Send, limit: int) -> None:
        response = JSONResponse({"detail": f"Request body too large (max {limit} bytes)"}, 413)
        await response(scope, receive, send)


# The API answers with JSON and images; nothing of it should run scripts, load resources or be framed.
_API_CSP = "default-src 'none'; frame-ancestors 'none'"
# Exceptions: the privacy policy page (inline <style>) and the interactive docs (Swagger UI / ReDoc from a CDN).
_PAGE_CSP = {
    "/privacy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
}
_NO_CSP = ("/docs", "/redoc")


class SecurityHeadersMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope["path"]
        csp = None if path.startswith(_NO_CSP) else _PAGE_CSP.get(path, _API_CSP)
        https = scope.get("scheme") == "https"

        async def send_with_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers.setdefault("X-Content-Type-Options", "nosniff")
                headers.setdefault("X-Frame-Options", "DENY")
                headers.setdefault("Referrer-Policy", "no-referrer")
                headers.setdefault("Cross-Origin-Resource-Policy", "cross-origin")  # photos are embedded by the frontend
                if csp:
                    headers.setdefault("Content-Security-Policy", csp)
                if https:
                    headers.setdefault("Strict-Transport-Security", "max-age=31536000")
            await send(message)

        await self.app(scope, receive, send_with_headers)
