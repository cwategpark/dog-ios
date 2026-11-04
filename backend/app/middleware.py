from starlette.responses import JSONResponse


class RequestGuardMiddleware:
    """Bound request bytes while receiving, including chunked requests with no length."""

    def __init__(self, app, settings):
        self.app = app
        self.settings = settings

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        limit = self.settings.max_upload_bytes + 128 * 1024 if path == "/v1/uploads" else 2 * 1024 * 1024 if path == "/webhooks/shopify" else 64 * 1024
        headers = dict(scope.get("headers", []))
        try:
            declared = int(headers.get(b"content-length", b"0"))
        except ValueError:
            return await JSONResponse({"detail": "invalid_content_length"}, status_code=400)(scope, receive, send)
        if declared < 0 or declared > limit:
            return await JSONResponse({"detail": "request_too_large"}, status_code=413)(scope, receive, send)
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunk = message.get("body", b"")
            if len(body) + len(chunk) > limit:
                return await JSONResponse({"detail": "request_too_large"}, status_code=413)(scope, receive, send)
            body.extend(chunk)
            if not message.get("more_body", False):
                break
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        async def private_headers(message):
            if message["type"] == "http.response.start":
                values = [(key, value) for key, value in message.get("headers", []) if key.lower() not in {b"cache-control", b"x-content-type-options", b"referrer-policy"}]
                values.extend([(b"cache-control", b"no-store"), (b"x-content-type-options", b"nosniff"), (b"referrer-policy", b"no-referrer")])
                message["headers"] = values
            await send(message)

        await self.app(scope, replay, private_headers)
