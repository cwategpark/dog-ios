import base64
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import httpx
from PIL import Image

from app.domain.service import ensure_configured, execute_job
from app.providers.errors import DomainValidationError, GenerationUncertain, ProviderNotConfigured
from app.providers.images import ImageProvider, fetch_product_image
from app.providers.shopify import ShopifyAdminClient


def png():
    result = io.BytesIO()
    Image.new("RGB", (8, 8), "green").save(result, "PNG")
    return result.getvalue()


SETTINGS = {"image_provider": "ark", "ark_api_key": "test-key", "ark_model": "doubao-seedream-5-0-flash-260915",
            "shopify_store_domain": "test-store.myshopify.com", "shopify_access_token": "test-token", "shopify_api_version": "2026-07"}


class ProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_official_shopify_session_authentication_is_cleared(self):
        import shopify

        requests = []
        def handler(request):
            requests.append(request)
            return httpx.Response(200, json={"data": {"shop": {"currencyCode": "USD"}}})
        client = httpx.Client(transport=httpx.MockTransport(handler))
        with patch("app.providers.shopify.httpx.Client", return_value=client):
            result = ShopifyAdminClient(SETTINGS)._execute_official("query { shop { currencyCode } }", {})
        self.assertEqual(result["data"]["shop"]["currencyCode"], "USD")
        self.assertEqual(requests[0].headers["x-shopify-access-token"], "test-token")
        self.assertIn("/admin/api/2026-07/graphql.json", str(requests[0].url))
        self.assertFalse(shopify.ShopifyResource.get_headers().get("X-Shopify-Access-Token"))

    async def test_ark_receives_byte_references_without_public_urls(self):
        def handler(request):
            body = json.loads(request.content)
            self.assertTrue(body["image"][0].startswith("data:image/png;base64,"))
            self.assertNotIn("stream", body)
            return httpx.Response(200, json={"data": [{"b64_json": base64.b64encode(png()).decode()}]})
        result, width, height = await ImageProvider(SETTINGS, httpx.MockTransport(handler)).generate("test", [png()])
        self.assertEqual((width, height), (8, 8))
        self.assertTrue(result.startswith(b"\x89PNG"))

    async def test_paid_timeout_has_no_automatic_retry(self):
        calls = []
        def handler(request):
            calls.append(request)
            raise httpx.ReadTimeout("test", request=request)
        with self.assertRaises(GenerationUncertain):
            await ImageProvider(SETTINGS, httpx.MockTransport(handler)).generate("test", [png()])
        self.assertEqual(len(calls), 1)

    async def test_reference_url_ssrf_is_rejected_before_transport(self):
        for url in ("http://127.0.0.1/private", "https://cdn.shopify.com.evil.invalid/x", "https://cdn.shopify.com@127.0.0.1/x"):
            with self.assertRaises(DomainValidationError):
                await fetch_product_image(url)

    async def test_cdn_redirect_is_not_followed(self):
        calls = []
        def handler(request):
            calls.append(request)
            return httpx.Response(302, headers={"location": "http://127.0.0.1/private"})
        with self.assertRaises(Exception):
            await fetch_product_image("https://cdn.shopify.com/x", httpx.MockTransport(handler))
        self.assertEqual(len(calls), 1)

    async def test_unconfigured_service_fails_instead_of_making_mock_output(self):
        with self.assertRaises(ProviderNotConfigured):
            ensure_configured("tryon", {})

    async def test_secret_credentials_are_unwrapped_only_for_provider_transport(self):
        from pydantic import SecretStr

        settings = {**SETTINGS, "ark_api_key": SecretStr("test-secret")}
        def handler(request):
            self.assertEqual(request.headers["authorization"], "Bearer test-secret")
            return httpx.Response(200, json={"data": [{"b64_json": base64.b64encode(png()).decode()}]})
        await ImageProvider(settings, httpx.MockTransport(handler)).generate("test", [png()])

    async def test_avatar_checkpoints_cartoon_before_reconstruction_failure(self):
        saved, checkpoints = [], []
        class Storage:
            def get_owned(self, upload_id):
                return SimpleNamespace(data=png())
            def save_output(self, data, mime_type, filename):
                saved.append(filename)
                return {"id": "cartoon-result", "url": "/v1/uploads/cartoon-result"}
        class FakeImage:
            async def generate(self, prompt, references):
                return png(), 8, 8
        class FakeModel:
            async def reconstruct(self, data):
                raise GenerationUncertain("unknown")
        context = {"settings": SETTINGS, "storage": Storage(), "image_provider": FakeImage(), "model_provider": FakeModel(),
                   "source_job": {"kind": "tryon", "status": "succeeded", "result": {"product_id": "gid://shopify/Product/1", "assets": [{"id": "preview", "role": "tryon"}]}},
                   "checkpoint": lambda stage, result: checkpoints.append((stage, result))}
        with self.assertRaises(GenerationUncertain):
            await execute_job("avatar", {"source_job_id": "source", "consent": True}, context)
        self.assertEqual(saved, ["pet-character.png"])
        self.assertEqual(checkpoints[0][0], "cartoon_ready")
        self.assertEqual(checkpoints[0][1]["assets"][0]["role"], "cartoon")

    async def test_shopify_variant_and_product_pagination(self):
        calls = []
        def raw(number):
            return {"id": f"gid://shopify/Product/{number}", "status": "ACTIVE", "onlineStoreUrl": "https://store.invalid/p",
                    "variants": {"nodes": [{"id": f"gid://shopify/ProductVariant/{number}", "price": "1", "inventoryItem": {"tracked": False}}],
                                 "pageInfo": {"hasNextPage": number == 1, "endCursor": "v1"}}}
        async def executor(query, variables):
            calls.append(variables)
            if "PawlyVariants" in query:
                return {"data": {"product": {"variants": {"nodes": [{"id": "gid://shopify/ProductVariant/9", "price": "2", "inventoryItem": {"tracked": False}}], "pageInfo": {"hasNextPage": False}}}}}
            number = 1 if variables["after"] is None else 2
            return {"data": {"shop": {"currencyCode": "USD"}, "products": {"nodes": [raw(number)], "pageInfo": {"hasNextPage": number == 1, "endCursor": "p1"}}}}
        result = await ShopifyAdminClient(SETTINGS, executor).fetch_catalog()
        self.assertEqual(len(result), 2)
        self.assertEqual(len(result[0]["variants"]), 2)
        self.assertEqual(len(calls), 3)

    async def test_tryon_rechecks_product_and_never_generates_for_unavailable_product(self):
        async def getter(product_id):
            return {"id": product_id, "status": "ARCHIVED", "published": False, "available": False}
        with self.assertRaises(DomainValidationError):
            await execute_job("tryon", {"consent": True, "product_id": "gid://shopify/Product/1"},
                              {"settings": SETTINGS, "storage": None, "product_getter": getter})

    async def test_tryon_stores_result_and_uses_selected_variant_image(self):
        saved, fetched = [], []
        class Storage:
            def get_owned(self, upload_id):
                self_id = upload_id
                return SimpleNamespace(data=png(), id=self_id)
            def save_output(self, data, mime_type, filename):
                saved.append((mime_type, filename))
                return {"id": "result-1", "url": "/v1/uploads/result-1"}
        class FakeProvider:
            async def generate(self, prompt, references):
                return png(), 8, 8
        async def getter(product_id):
            return {"id": product_id, "status": "ACTIVE", "published": True, "available": True, "tryon_enabled": True,
                    "variants": [{"id": "gid://shopify/ProductVariant/2", "available": True, "image": "https://cdn.shopify.com/variant.png"}]}
        async def fetcher(url):
            fetched.append(url)
            return png()
        result = await execute_job("tryon", {"consent": True, "pet_upload_id": "u1", "product_id": "gid://shopify/Product/1", "variant_id": "gid://shopify/ProductVariant/2"},
                                   {"settings": SETTINGS, "storage": Storage(), "product_getter": getter, "product_image_fetcher": fetcher, "image_provider": FakeProvider()})
        self.assertEqual(result["assets"][0]["role"], "tryon")
        self.assertEqual(fetched, ["https://cdn.shopify.com/variant.png"])
        self.assertEqual(saved, [("image/png", "pet-preview.png")])
