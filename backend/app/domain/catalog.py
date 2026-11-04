"""Map Shopify native IDs and product state without depending on WooCommerce."""
import json
import re
from decimal import Decimal, InvalidOperation

from app.providers.errors import DomainValidationError

PRODUCT_ID = re.compile(r"^gid://shopify/Product/[1-9][0-9]*$")
VARIANT_ID = re.compile(r"^gid://shopify/ProductVariant/[1-9][0-9]*$")


def connection_nodes(value):
    if isinstance(value, list):
        return value
    value = value or {}
    return value.get("nodes") or [edge["node"] for edge in value.get("edges", [])]


def decimal_price(value):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError) as error:
        raise DomainValidationError("Invalid product price.") from error
    if not result.is_finite() or result < 0:
        raise DomainValidationError("Invalid product price.")
    return result


def _metafields(node):
    output = {}
    for field in connection_nodes(node.get("metafields")):
        if field.get("namespace") != "pawly":
            continue
        value = field.get("jsonValue")
        if value is None:
            value = field.get("value")
            try:
                value = json.loads(value)
            except (TypeError, ValueError):
                pass
        output[field["key"]] = value
    return output


def _media_images(node: dict, *, variant=False) -> list[dict]:
    """Current Admin media takes precedence; legacy images remain readable offline."""
    if "media" in node:
        return [media["image"] for media in connection_nodes(node.get("media"))
                if isinstance(media.get("image"), dict) and media["image"].get("url")]
    if variant:
        image = node.get("image")
        return [image] if isinstance(image, dict) and image.get("url") else []
    return connection_nodes(node.get("images"))


def map_shopify_product(node: dict, currency: str = "USD") -> dict:
    product_id = str(node.get("id", ""))
    if not PRODUCT_ID.fullmatch(product_id):
        raise DomainValidationError("A Shopify product GID is required.")
    fields = _metafields(node)
    tags = [str(tag).strip().lower() for tag in node.get("tags", [])]
    variants = []
    for raw in connection_nodes(node.get("variants")):
        variant_id = str(raw.get("id", ""))
        if not VARIANT_ID.fullmatch(variant_id):
            raise DomainValidationError("A Shopify variant GID is required.")
        tracked = raw.get("inventoryItem", {}).get("tracked", True)
        available = not tracked or raw.get("inventoryPolicy") == "CONTINUE" or (raw.get("sellableOnlineQuantity") or 0) > 0
        images = _media_images(raw, variant=True)
        variants.append({"id": variant_id, "title": raw.get("title", ""),
                         "price": str(decimal_price(raw.get("price"))),
                         "available": available, "image": images[0]["url"] if images else None,
                         "selected_options": raw.get("selectedOptions", [])})
    pet_types = fields.get("pet_types")
    if not isinstance(pet_types, list):
        pet_types = [pet for pet in ("cat", "dog") if pet in tags or f"pet:{pet}" in tags]
    categories = fields.get("categories")
    if not isinstance(categories, list):
        categories = [tag.removeprefix("category:") for tag in tags if tag.startswith("category:")]
    online_url = node.get("onlineStoreUrl")
    purchasable_variants = [variant for variant in variants if variant["available"]]
    price = min((decimal_price(variant["price"]) for variant in purchasable_variants), default=None)
    active = node.get("status") == "ACTIVE"
    return {
        "id": product_id, "handle": node.get("handle", ""), "title": node.get("title", ""),
        "description": node.get("description", ""), "status": node.get("status", "DRAFT"),
        "published": bool(online_url), "available": bool(active and online_url and purchasable_variants),
        "url": online_url, "currency": currency, "price": str(price) if price is not None else None,
        "variants": variants, "images": _media_images(node), "tags": tags,
        "categories": categories, "pet_types": pet_types,
        "dog_sizes": fields.get("dog_sizes", []), "min_age_months": fields.get("min_age_months"),
        "max_age_months": fields.get("max_age_months"),
        "owner_accessory": fields.get("owner_accessory") is True,
        "needs_fit_check": fields.get("needs_fit_check") is True or "wear" in categories or "leashes" in categories or len(variants) > 1,
        "excluded_from_gifts": fields.get("exclude_gift") is True,
        "tryon_enabled": fields.get("tryon_enabled") is True,
        "tryon_usage": fields.get("tryon_usage", ""),
        "model_url": fields.get("model_url"), "fitting": fields.get("fitting"),
        "updated_at": node.get("updatedAt"),
    }


def eligible_products(catalog: list[dict]) -> list[dict]:
    return [product for product in catalog
            if product.get("status") == "ACTIVE" and product.get("published") is True
            and product.get("available") is True and not product.get("excluded_from_gifts")
            and (product.get("pet_types") or product.get("owner_accessory"))]
