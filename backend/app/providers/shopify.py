"""Read-only Admin GraphQL adapter using Shopify's official Python session client."""
import asyncio
import json
import re
import threading

import httpx

from app.domain.catalog import PRODUCT_ID, map_shopify_product
from app.providers.errors import DomainValidationError, ProviderFailure, ProviderNotConfigured
from app.providers.images import _setting

_SESSION_LOCK = threading.Lock()

VARIANT_FIELDS = """
id title price sellableOnlineQuantity inventoryPolicy
inventoryItem { tracked }
media(first: 1) { nodes { ... on MediaImage { image { url altText } } } }
selectedOptions { name value }
"""

PRODUCT_FIELDS = """
id handle title description status onlineStoreUrl updatedAt tags
media(first: 8) { nodes { ... on MediaImage { image { url altText } } } }
metafields(first: 30, namespace: "pawly") { nodes { namespace key jsonValue } }
variants(first: 25) {
  nodes { """ + VARIANT_FIELDS + """ }
  pageInfo { hasNextPage endCursor }
}
"""

CATALOG_QUERY = """
query PawlyCatalog($after: String) {
  shop { currencyCode }
  products(first: 10, after: $after) {
    nodes { """ + PRODUCT_FIELDS + """ }
    pageInfo { hasNextPage endCursor }
  }
}
"""

PRODUCT_QUERY = """
query PawlyProduct($id: ID!) {
  shop { currencyCode }
  product(id: $id) { """ + PRODUCT_FIELDS + """ }
}
"""

VARIANTS_QUERY = """
query PawlyVariants($id: ID!, $after: String) {
  product(id: $id) {
    variants(first: 100, after: $after) {
      nodes { """ + VARIANT_FIELDS + """ }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""


class ShopifyAdminClient:
    def __init__(self, settings, executor=None):
        self.domain = _setting(settings, "shopify_store_domain", "")
        self.token = _setting(settings, "shopify_access_token", "")
        if hasattr(self.token, "get_secret_value"):
            self.token = self.token.get_secret_value()
        self.version = _setting(settings, "shopify_api_version", "2026-07")
        self.executor = executor

    def ensure_configured(self):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.myshopify\.com", self.domain) or not self.token:
            raise ProviderNotConfigured("A Shopify store domain and server-side access token are required.")
        if not re.fullmatch(r"20[0-9]{2}-(01|04|07|10)", self.version):
            raise ProviderNotConfigured("Pin a stable Shopify Admin API version.")

    def _execute_official(self, query, variables):
        import shopify

        with _SESSION_LOCK:
            session = shopify.Session(self.domain, self.version, self.token)
            try:
                shopify.ShopifyResource.activate_session(session)
                graphql = shopify.GraphQL()
                endpoint, headers = graphql.endpoint, dict(graphql.headers)
            finally:
                shopify.ShopifyResource.clear_session()
        # The official GraphQL.execute helper uses urllib without a request timeout.
        # Retain its authenticated endpoint/headers and apply bounded HTTP transport.
        with httpx.Client(timeout=30, follow_redirects=False, trust_env=False) as client:
            response = client.post(endpoint, headers=headers, json={"query": query, "variables": variables})
            response.raise_for_status()
            return response.json()

    async def _query(self, query, variables):
        self.ensure_configured()
        for attempt in range(3):
            try:
                if self.executor:
                    body = await self.executor(query, variables)
                else:
                    body = await asyncio.to_thread(self._execute_official, query, variables)
            except Exception as error:
                raise ProviderFailure("Shopify catalog could not be read.") from error
            errors = body.get("errors") or []
            throttled = errors and all(error.get("extensions", {}).get("code") == "THROTTLED" for error in errors)
            if throttled and attempt < 2:
                await asyncio.sleep(2 ** attempt)
                continue
            if errors or not isinstance(body.get("data"), dict):
                raise ProviderFailure("Shopify returned a catalog error.")
            return body["data"]
        raise ProviderFailure("Shopify catalog rate limit exceeded.")

    async def _all_variants(self, node):
        connection = node.get("variants") or {"nodes": [], "pageInfo": {}}
        variants = list(connection.get("nodes", []))
        seen_cursors = set()
        while connection.get("pageInfo", {}).get("hasNextPage"):
            cursor = connection["pageInfo"].get("endCursor")
            if not cursor or cursor in seen_cursors:
                raise ProviderFailure("Shopify returned a non-advancing variant page.")
            seen_cursors.add(cursor)
            data = await self._query(VARIANTS_QUERY, {"id": node["id"], "after": cursor})
            if data.get("product") is None:
                return None
            connection = data["product"]["variants"]
            variants.extend(connection.get("nodes", []))
        node["variants"] = {"nodes": variants}
        return node

    async def fetch_product(self, product_id: str) -> dict | None:
        if not PRODUCT_ID.fullmatch(product_id):
            raise DomainValidationError("A Shopify product GID is required.")
        data = await self._query(PRODUCT_QUERY, {"id": product_id})
        node = data.get("product")
        if node is None:
            return None
        node = await self._all_variants(node)
        return map_shopify_product(node, data["shop"]["currencyCode"]) if node else None

    async def fetch_catalog(self) -> list[dict]:
        output, cursor, seen = [], None, set()
        while True:
            data = await self._query(CATALOG_QUERY, {"after": cursor})
            connection = data["products"]
            currency = data["shop"]["currencyCode"]
            for raw in connection["nodes"]:
                node = await self._all_variants(raw)
                if node:
                    output.append(map_shopify_product(node, currency))
            page = connection["pageInfo"]
            if not page["hasNextPage"]:
                return output
            cursor = page.get("endCursor")
            if not cursor or cursor in seen:
                raise ProviderFailure("Shopify returned a non-advancing product page.")
            seen.add(cursor)
