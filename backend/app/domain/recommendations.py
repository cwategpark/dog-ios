"""Published 2026-10-21 workflow rules; no LLM and no invented product IDs."""
from decimal import Decimal

from app.domain.catalog import decimal_price, eligible_products
from app.providers.errors import DomainValidationError

RULE_VERSION = "pawly-published-2026-10-21"
PRIORITIES = ("toys", "cleanup", "beds", "wear", "leashes", "litter", "bags")


def normalize_pet(profile: dict) -> dict:
    if not isinstance(profile, dict):
        raise DomainValidationError("A pet profile is required.")
    if "user_pets" in profile:
        pets = profile["user_pets"]
        if not isinstance(pets, list) or not pets or not isinstance(pets[0], dict):
            raise DomainValidationError("At least one valid pet profile is required.")
        pet = pets[0].get("pet_information", {})
    else:
        pet = profile.get("pet_information", profile)
    if not isinstance(pet, dict):
        raise DomainValidationError("A valid pet profile is required.")
    species = str(pet.get("type", pet.get("pet_type", ""))).lower()
    age = pet.get("age_months")
    if species not in ("cat", "dog") or isinstance(age, bool) or not str(age).isdigit() or not 0 <= int(age) <= 480:
        raise DomainValidationError("Choose cat or dog and an age between 0 and 480 months.")
    size = pet.get("dog_size") if species == "dog" else None
    if species == "dog" and size not in ("small", "medium", "large"):
        raise DomainValidationError("Choose a dog size.")
    return {"type": species, "age_months": int(age), "dog_size": size}


def recommend(profile: dict, catalog: list[dict], budget: Decimal | None = None, currency: str | None = None) -> dict:
    """The optional budget is internal only; existing workflows have no budget UI."""
    pet = normalize_pet(profile)
    matches = []
    for product in eligible_products(catalog):
        if pet["type"] not in product.get("pet_types", []) and not product.get("owner_accessory"):
            continue
        low, high = product.get("min_age_months"), product.get("max_age_months")
        if low is not None and pet["age_months"] < int(low):
            continue
        if high is not None and pet["age_months"] > int(high):
            continue
        sizes = product.get("dog_sizes") or []
        if pet["type"] == "dog" and sizes and pet["dog_size"] not in sizes:
            continue
        if budget is not None:
            if currency != product.get("currency"):
                continue
            if decimal_price(product.get("price")) > decimal_price(budget):
                continue
        matches.append(product)
    matches.sort(key=lambda product: (min((PRIORITIES.index(category) for category in product.get("categories", []) if category in PRIORITIES), default=99), int(product["id"].rsplit("/", 1)[1])))
    selected, used_kinds = [], set()
    for product in matches:
        kind = next((category for category in PRIORITIES if category in product.get("categories", [])), "other")
        if kind not in used_kinds:
            selected.append(product)
            used_kinds.add(kind)
        if len(selected) == 3:
            break
    for product in matches:
        if len(selected) == 3:
            break
        if all(existing["id"] != product["id"] for existing in selected):
            selected.append(product)
    return {"schema_version": "1.0", "rule_version": RULE_VERSION, "source": "rules",
            "product_ids": [product["id"] for product in selected], "products": selected,
            "selected_count": len(selected), "requested_count": 3,
            "status": "ready" if len(selected) == 3 else "partial" if selected else "empty",
            "items": [{"product_id": product["id"], "fit_confirmation_required": bool(product.get("needs_fit_check"))} for product in selected]}


def revalidate_selection(product_ids: list[str], fresh_catalog: list[dict], profile: dict) -> list[dict]:
    """Only return selected IDs still eligible in a freshly fetched catalog."""
    target = set(product_ids)
    eligible = recommend_all(profile, fresh_catalog)
    return [eligible[product_id] for product_id in dict.fromkeys(product_ids) if product_id in eligible and product_id in target][:3]


def recommend_all(profile, catalog):
    pet = normalize_pet(profile)
    result = {}
    for product in eligible_products(catalog):
        if pet["type"] not in product.get("pet_types", []) and not product.get("owner_accessory"):
            continue
        if product.get("min_age_months") is not None and pet["age_months"] < int(product["min_age_months"]):
            continue
        if product.get("max_age_months") is not None and pet["age_months"] > int(product["max_age_months"]):
            continue
        if pet["type"] == "dog" and product.get("dog_sizes") and pet["dog_size"] not in product["dog_sizes"]:
            continue
        result[product["id"]] = product
    return result
