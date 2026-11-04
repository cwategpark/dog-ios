"""Direct image providers; request bodies hold bytes, never Dify file URLs."""
import base64
import io
from urllib.parse import urlsplit

import httpx
from PIL import Image, ImageOps, UnidentifiedImageError

from app.providers.errors import DomainValidationError, GenerationUncertain, ProviderFailure, ProviderNotConfigured

MAX_IMAGE_BYTES = 20 * 1024 * 1024
MAX_PIXELS = 24_000_000
ARK_ENDPOINT = "https://ark.cn-beijing.volces.com/api/v3/images/generations"


def _setting(settings, key, default=None):
    value = settings.get(key, default) if isinstance(settings, dict) else getattr(settings, key, default)
    return value.get_secret_value() if hasattr(value, "get_secret_value") else value


def image_bytes(data: bytes, *, upload=False) -> tuple[bytes, int, int]:
    if not data or len(data) > (8 * 1024 * 1024 if upload else MAX_IMAGE_BYTES):
        raise DomainValidationError("Image size exceeds the allowed limit.")
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format not in ("PNG", "JPEG", "WEBP") or image.width * image.height > MAX_PIXELS:
                raise DomainValidationError("Use a JPEG, PNG or WebP image under 24 megapixels.")
            image = ImageOps.exif_transpose(image).convert("RGB")
            if upload:
                image.thumbnail((1536, 1536))
            width, height = image.size
            output = io.BytesIO()
            image.save(output, format="PNG")
            result = output.getvalue()
            if len(result) > MAX_IMAGE_BYTES:
                raise DomainValidationError("Decoded image exceeds the allowed limit.")
            return result, width, height
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as error:
        raise DomainValidationError("The image could not be decoded.") from error


def _data_uri(data: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(data).decode("ascii")


def ensure_image_configured(settings):
    provider = _setting(settings, "image_provider", "ark")
    if provider == "ark" and _setting(settings, "ark_api_key") and _setting(settings, "ark_model"):
        return
    if provider == "gemini" and all(_setting(settings, field) for field in ("gemini_api_key", "gemini_model", "gemini_endpoint")):
        endpoint = urlsplit(_setting(settings, "gemini_endpoint"))
        if endpoint.scheme == "https" and endpoint.hostname == "generativelanguage.googleapis.com" and not endpoint.username:
            return
    raise ProviderNotConfigured("The selected image provider is not configured.")


class ImageProvider:
    def __init__(self, settings, transport=None):
        self.settings = settings
        self.transport = transport

    async def generate(self, prompt: str, references: list[bytes]) -> tuple[bytes, int, int]:
        ensure_image_configured(self.settings)
        if not 1 <= len(references) <= 3:
            raise DomainValidationError("One to three reference images are required.")
        refs = [image_bytes(data, upload=True)[0] for data in references]
        provider = _setting(self.settings, "image_provider", "ark")
        if provider == "ark":
            endpoint = ARK_ENDPOINT
            model = _setting(self.settings, "ark_model")
            headers = {"Authorization": "Bearer " + _setting(self.settings, "ark_api_key")}
            payload = {"model": model, "prompt": prompt, "image": [_data_uri(data) for data in refs],
                       "size": "2048x2048", "response_format": "b64_json", "watermark": True}
            if not model.startswith(("doubao-seedream-5-0-flash-", "doubao-seedream-5-0-pro-")):
                payload.update(stream=False, sequential_image_generation="disabled")
        else:
            endpoint = _setting(self.settings, "gemini_endpoint")
            headers = {"x-goog-api-key": _setting(self.settings, "gemini_api_key")}
            payload = {"model": _setting(self.settings, "gemini_model"),
                       "input": [{"type": "text", "text": prompt}] + [
                           {"type": "image", "mime_type": "image/png", "data": base64.b64encode(data).decode("ascii")} for data in refs],
                       "response_format": {"type": "image", "mime_type": "image/jpeg", "aspect_ratio": "1:1", "image_size": "2K"},
                       "store": False, "stream": False}
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(float(_setting(self.settings, "provider_timeout_seconds", 480)), connect=15),
                                         follow_redirects=False, trust_env=False, transport=self.transport) as client:
                response = await client.post(endpoint, headers=headers, json=payload)
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            raise GenerationUncertain("The provider outcome is unknown. Automatic retries are disabled.") from error
        if response.status_code >= 500:
            raise GenerationUncertain("The provider outcome is unknown. Check provider records before retrying.")
        if response.status_code != 200:
            raise ProviderFailure(f"Image provider rejected the request (HTTP {response.status_code}).")
        try:
            body = response.json()
            if provider == "ark":
                rows = body.get("data", [])
                if len(rows) != 1 or not rows[0].get("b64_json"):
                    raise ValueError("No unique image")
                encoded = rows[0]["b64_json"]
            else:
                if body.get("status") != "completed":
                    raise ValueError("Incomplete generation")
                rows = [part for step in body.get("steps", []) if step.get("type") == "model_output"
                        for part in step.get("content", []) if part.get("type") == "image"]
                if len(rows) != 1:
                    raise ValueError("No unique image")
                encoded = rows[0]["data"]
            if len(encoded) > MAX_IMAGE_BYTES * 4 // 3 + 8:
                raise ValueError("Image too large")
            return image_bytes(base64.b64decode(encoded, validate=True))
        except (KeyError, TypeError, ValueError, DomainValidationError) as error:
            raise GenerationUncertain("The provider returned an unusable result. Automatic retries are disabled.") from error


async def fetch_product_image(url: str, transport=None) -> bytes:
    """Only fetch a server-selected Shopify CDN image; no redirects or caller URLs."""
    parsed = urlsplit(str(url))
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443) or not (
        host == "cdn.shopify.com" or host.endswith(".shopifycdn.com") or host == "shopifycdn.com"
    ):
        raise DomainValidationError("The product reference must be hosted on the Shopify CDN.")
    async with httpx.AsyncClient(timeout=30, follow_redirects=False, trust_env=False, transport=transport) as client:
        async with client.stream("GET", url) as response:
            if response.status_code != 200:
                raise ProviderFailure("The product reference could not be loaded.")
            chunks, size = [], 0
            async for chunk in response.aiter_bytes():
                size += len(chunk)
                if size > MAX_IMAGE_BYTES:
                    raise ProviderFailure("The product reference is too large.")
                chunks.append(chunk)
    return image_bytes(b"".join(chunks), upload=True)[0]
