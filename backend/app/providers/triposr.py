"""Configured Gradio TripoSR protocol. No inference is retried automatically."""
import json
import re
import struct
from urllib.parse import quote, urlsplit

import httpx

from app.providers.errors import GenerationUncertain, ProviderFailure, ProviderNotConfigured
from app.providers.images import _setting


def ensure_triposr_configured(settings):
    base = _setting(settings, "triposr_base_url", "")
    parsed = urlsplit(base)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ProviderNotConfigured("The private TripoSR service is not configured.")


class TripoSRProvider:
    def __init__(self, settings, transport=None):
        self.settings = settings
        self.transport = transport

    async def reconstruct(self, image: bytes) -> tuple[bytes, dict]:
        ensure_triposr_configured(self.settings)
        base = _setting(self.settings, "triposr_base_url").rstrip("/")
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(900, connect=15), follow_redirects=False, trust_env=False, transport=self.transport) as client:
                response = await client.post(base + "/upload", files={"files": ("character.png", image, "image/png")})
                response.raise_for_status()
                uploaded = response.json()
                if not isinstance(uploaded, list) or len(uploaded) != 1 or not isinstance(uploaded[0], str):
                    raise ProviderFailure("The reconstruction service returned an invalid upload.")
                file = {"path": uploaded[0], "meta": {"_type": "gradio.FileData"}}
                processed = (await self._call(client, base, "preprocess", [file, True, 0.85]))[0]
                outputs = await self._call(client, base, "generate_lowpoly", [processed, 256, 5000])
                model = outputs[1]
                path = model["path"] if isinstance(model, dict) else model
                if not isinstance(path, str) or not (re.fullmatch(r"/app/output/[a-f0-9]{32}/mesh\.glb", path) or re.fullmatch(r"/tmp/gradio/[a-f0-9]{32,64}/mesh\.glb", path)):
                    raise ProviderFailure("The reconstruction service returned an unsupported output path.")
                async with client.stream("GET", base + "/file=" + quote(path, safe="/")) as download:
                    download.raise_for_status()
                    chunks, size = [], 0
                    async for chunk in download.aiter_bytes():
                        size += len(chunk)
                        if size > 25 * 1024 * 1024:
                            raise ProviderFailure("The reconstructed model is too large.")
                        chunks.append(chunk)
                data = b"".join(chunks)
                if len(data) <= 100 or data[:4] != b"glTF" or struct.unpack("<II", data[4:12]) != (2, len(data)):
                    raise ProviderFailure("The reconstruction service returned an invalid GLB.")
                stats = outputs[2]
                faces, vertices = int(stats["faces"]), int(stats["vertices"])
                if not 0 < faces <= 5000 or vertices <= 0:
                    raise ProviderFailure("The reconstructed model failed the geometry limits.")
                return data, {"faces": faces, "vertices": vertices}
        except (httpx.TimeoutException, httpx.NetworkError) as error:
            raise GenerationUncertain("The reconstruction outcome is unknown. Do not resubmit inference automatically.") from error
        except (httpx.HTTPStatusError, KeyError, TypeError, ValueError, IndexError) as error:
            raise ProviderFailure("The reconstruction service failed.") from error

    @staticmethod
    async def _call(client, base, name, data):
        response = await client.post(base + "/call/" + name, json={"data": data})
        response.raise_for_status()
        event_id = response.json().get("event_id")
        if not isinstance(event_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", event_id):
            raise ProviderFailure("The reconstruction queue returned an invalid event.")
        async with client.stream("GET", base + "/call/" + name + "/" + event_id) as stream:
            stream.raise_for_status()
            event = ""
            async for line in stream.aiter_lines():
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    if event == "complete":
                        return json.loads(line[5:])
                    if event == "error":
                        raise ProviderFailure("The reconstruction inference failed.")
        raise GenerationUncertain("The reconstruction queue ended without a result.")
