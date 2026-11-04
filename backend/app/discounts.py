"""Gift offer policy and platform boundary. This module never changes cart prices.

Checkout evidence is an internal adapter result, never a browser request model.
There is deliberately no working Shopify discount adapter until its installation,
plan and checkout enforcement capabilities have been verified.
"""
from dataclasses import dataclass
from decimal import Decimal
from enum import StrEnum
import hashlib
import re
from typing import Protocol

from pydantic import BaseModel, ConfigDict, Field

from .domain.catalog import PRODUCT_ID, VARIANT_ID


PERCENTAGE = Decimal("20")
OFFER_TTL_SECONDS = 2 * 60 * 60
POLICY_VERSION = "first-order-three-products-v1"
SHOP = re.compile(r"[a-z0-9][a-z0-9-]*\.myshopify\.com")


class DiscountConfigurationUnavailable(RuntimeError):
    status_code = 503
    code = "discount_platform_not_configured"


class DiscountContractError(ValueError):
    pass


class DecisionReason(StrEnum):
    ELIGIBLE = "eligible_pending_shopify_application"
    NOT_STARTED = "offer_not_started"
    EXPIRED = "offer_expired"
    OWNER_MISMATCH = "offer_owner_mismatch"
    SHOP_MISMATCH = "shop_mismatch"
    CART_MISMATCH = "cart_binding_mismatch"
    STALE_CHECKOUT = "checkout_confirmation_stale"
    FIRST_ORDER_UNKNOWN = "shopify_first_order_not_confirmed"
    NOT_FIRST_ORDER = "not_first_order"
    BUNDLE_INCOMPLETE = "three_selected_products_required"
    VARIANT_UNAVAILABLE = "selected_variant_unavailable"
    CURRENCY_MISMATCH = "mixed_currency_not_supported"
    OTHER_DISCOUNT = "discount_combination_not_allowed"


class FirstOrderStatus(StrEnum):
    CONFIRMED_ELIGIBLE = "confirmed_eligible"
    CONFIRMED_INELIGIBLE = "confirmed_ineligible"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class SelectedVariant:
    product_id: str
    variant_id: str

    def __post_init__(self):
        if not PRODUCT_ID.fullmatch(self.product_id) or not VARIANT_ID.fullmatch(self.variant_id):
            raise DiscountContractError("Native Shopify product and variant GIDs are required")


@dataclass(frozen=True)
class GiftOffer:
    id: str
    shop: str
    owner_id: str
    selected: tuple[SelectedVariant, ...]
    issued_at: int
    expires_at: int
    policy_version: str = POLICY_VERSION

    def __post_init__(self):
        if not re.fullmatch(r"[a-f0-9]{32}", self.id) or not self.owner_id or not SHOP.fullmatch(self.shop):
            raise DiscountContractError("An offer requires server-owned identity and store scope")
        if len(self.selected) != 3 or len({item.product_id for item in self.selected}) != 3:
            raise DiscountContractError("An offer contains exactly three different products")
        if len({item.variant_id for item in self.selected}) != 3:
            raise DiscountContractError("Each selected product requires its own variant")
        if type(self.issued_at) is not int or type(self.expires_at) is not int or self.expires_at - self.issued_at != OFFER_TTL_SECONDS:
            raise DiscountContractError("An offer is valid for exactly two hours")
        if self.policy_version != POLICY_VERSION:
            raise DiscountContractError("Unsupported offer policy")


def build_offer(*, offer_id: str, shop: str, owner_id: str, selected: tuple[SelectedVariant, ...],
                recommended_product_ids: tuple[str, ...], now: int) -> GiftOffer:
    """Create only from the persisted, server-produced three-item recommendation."""
    if len(recommended_product_ids) != 3 or len(set(recommended_product_ids)) != 3:
        raise DiscountContractError("A full trusted three-product recommendation is required")
    if set(recommended_product_ids) != {item.product_id for item in selected}:
        raise DiscountContractError("Selected products do not match the trusted recommendation")
    return GiftOffer(offer_id, shop, owner_id, selected, now, now + OFFER_TTL_SECONDS)


class DealClientRequest(BaseModel):
    """Safe future endpoint body. No price, email or eligibility assertions allowed."""
    model_config = ConfigDict(extra="forbid", strict=True)
    offer_id: str = Field(pattern=r"^[a-f0-9]{32}$")
    cart_reference: str = Field(min_length=8, max_length=160, pattern=r"^[A-Za-z0-9_-]+$")


@dataclass(frozen=True)
class PlatformEligibilityRequest:
    offer_id: str
    shop: str
    owner_id: str
    cart_reference: str
    selected: tuple[SelectedVariant, ...]
    policy_version: str = POLICY_VERSION
    revalidate_at_checkout: bool = True
    atomic_redemption_required: bool = True


def eligibility_request(offer: GiftOffer, body: DealClientRequest, *, authenticated_owner_id: str,
                        authenticated_shop: str) -> PlatformEligibilityRequest:
    if offer.id != body.offer_id or offer.owner_id != authenticated_owner_id or offer.shop != authenticated_shop:
        raise DiscountContractError("The persisted offer is not owned by this authenticated session/store")
    return PlatformEligibilityRequest(offer.id, offer.shop, offer.owner_id, body.cart_reference, offer.selected)


@dataclass(frozen=True)
class ShopifyCartLine:
    id: str
    product_id: str
    variant_id: str
    quantity: int
    available: bool
    unit_price: Decimal
    currency: str

    def __post_init__(self):
        if not self.id or len(self.id) > 512 or any(ord(char) < 32 for char in self.id):
            raise DiscountContractError("A Shopify cart line ID is required")
        SelectedVariant(self.product_id, self.variant_id)
        if type(self.quantity) is not int or self.quantity < 0 or type(self.available) is not bool:
            raise DiscountContractError("Invalid cart line quantity or availability")
        if not isinstance(self.unit_price, Decimal) or not self.unit_price.is_finite() or self.unit_price < 0:
            raise DiscountContractError("Money must be a finite non-negative Decimal from Shopify")
        if not re.fullmatch(r"[A-Z]{3}", self.currency):
            raise DiscountContractError("A Shopify presentment currency is required")


@dataclass(frozen=True)
class ShopifyCheckoutEvidence:
    """Issued exclusively by a trusted platform adapter after a Shopify check.

    Constructing this dataclass does not authenticate a request. Never deserialize
    browser JSON into it. Customer email and submitted booleans cannot produce it.
    """
    shop: str
    owner_id: str
    cart_reference: str
    buyer_reference: str | None
    first_order_status: FirstOrderStatus
    confirmed_at: int
    cart_bound_to_owner: bool
    lines: tuple[ShopifyCartLine, ...]
    other_discount_present: bool
    checkout_currency: str


@dataclass(frozen=True)
class DiscountTarget:
    cart_line_id: str
    product_id: str
    variant_id: str
    quantity: int = 1


@dataclass(frozen=True)
class DiscountInstruction:
    """Internal instruction, intentionally not a Shopify API payload or final total."""
    offer_id: str
    shop: str
    buyer_reference: str
    cart_reference: str
    percentage: Decimal
    targets: tuple[DiscountTarget, ...]
    expires_at: int
    redemption_scope: str = ""
    combines_with_product_discounts: bool = False
    combines_with_order_discounts: bool = False
    combines_with_shipping_discounts: bool = False
    require_first_order_revalidation: bool = True
    maximum_redemptions: int = 1
    rounding_authority: str = "shopify"


@dataclass(frozen=True)
class DiscountDecision:
    eligible: bool
    reason: DecisionReason
    instruction: DiscountInstruction | None = None


def evaluate_offer(offer: GiftOffer, request: PlatformEligibilityRequest, evidence: ShopifyCheckoutEvidence,
                   *, now: int, evidence_max_age_seconds: int = 60) -> DiscountDecision:
    def deny(reason):
        return DiscountDecision(False, reason)

    if request.offer_id != offer.id or request.owner_id != offer.owner_id or evidence.owner_id != offer.owner_id:
        return deny(DecisionReason.OWNER_MISMATCH)
    if request.shop != offer.shop or evidence.shop != offer.shop:
        return deny(DecisionReason.SHOP_MISMATCH)
    if request.policy_version != offer.policy_version or request.selected != offer.selected or not request.revalidate_at_checkout or not request.atomic_redemption_required:
        raise DiscountContractError("Eligibility request weakens the immutable offer policy")
    if evidence.cart_reference != request.cart_reference or evidence.cart_bound_to_owner is not True:
        return deny(DecisionReason.CART_MISMATCH)
    if now < offer.issued_at:
        return deny(DecisionReason.NOT_STARTED)
    if now >= offer.expires_at:
        return deny(DecisionReason.EXPIRED)
    if evidence.confirmed_at > now or now - evidence.confirmed_at > evidence_max_age_seconds:
        return deny(DecisionReason.STALE_CHECKOUT)
    if evidence.first_order_status is FirstOrderStatus.CONFIRMED_INELIGIBLE:
        return deny(DecisionReason.NOT_FIRST_ORDER)
    if evidence.first_order_status is not FirstOrderStatus.CONFIRMED_ELIGIBLE or not evidence.buyer_reference:
        return deny(DecisionReason.FIRST_ORDER_UNKNOWN)
    if evidence.other_discount_present:
        return deny(DecisionReason.OTHER_DISCOUNT)
    if len({line.id for line in evidence.lines}) != len(evidence.lines):
        raise DiscountContractError("Shopify cart line IDs must be unique")
    targets = []
    for selected in offer.selected:
        matches = [line for line in evidence.lines if line.product_id == selected.product_id
                   and line.variant_id == selected.variant_id and line.quantity > 0]
        if not matches:
            return deny(DecisionReason.BUNDLE_INCOMPLETE)
        available = [line for line in matches if line.available]
        if not available:
            return deny(DecisionReason.VARIANT_UNAVAILABLE)
        line = min(available, key=lambda line: line.id)
        if line.currency != evidence.checkout_currency:
            return deny(DecisionReason.CURRENCY_MISMATCH)
        # Choose one line per product even when a variant is split into several lines.
        targets.append(DiscountTarget(line.id, selected.product_id, selected.variant_id))
    scope = hashlib.sha256(f"{offer.shop}:{offer.policy_version}:{evidence.buyer_reference}".encode()).hexdigest()
    instruction = DiscountInstruction(offer.id, offer.shop, evidence.buyer_reference, request.cart_reference,
                                      PERCENTAGE, tuple(targets), offer.expires_at, redemption_scope=scope)
    return DiscountDecision(True, DecisionReason.ELIGIBLE, instruction)


@dataclass(frozen=True)
class UnroundedEstimate:
    currency: str
    base_amount: Decimal
    discount_amount: Decimal
    payable_amount: Decimal
    final: bool = False
    rounding_authority: str = "shopify"


def unrounded_estimate(instruction: DiscountInstruction, evidence: ShopifyCheckoutEvidence) -> UnroundedEstimate:
    """Diagnostic only. No two-decimal assumption for JPY, KWD or presentment FX."""
    if instruction.cart_reference != evidence.cart_reference or instruction.shop != evidence.shop:
        raise DiscountContractError("Estimate evidence must match the accepted checkout")
    prices = {line.id: line for line in evidence.lines}
    base = Decimal("0")
    for target in instruction.targets:
        line = prices.get(target.cart_line_id)
        if line is None or line.product_id != target.product_id or line.variant_id != target.variant_id or line.currency != evidence.checkout_currency:
            raise DiscountContractError("Estimate lines do not match the platform instruction")
        base += line.unit_price * target.quantity
    discount = base * instruction.percentage / Decimal("100")
    return UnroundedEstimate(evidence.checkout_currency, base, discount, base - discount)


@dataclass(frozen=True)
class DiscountCapabilities:
    configured: bool = False
    checkout_first_order_check: bool = False
    exact_three_product_selection: bool = False
    maximum_one_unit_per_product: bool = False
    non_combining: bool = False
    two_hour_expiry: bool = False
    atomic_single_redemption: bool = False
    mode: str = "unavailable"

    @property
    def available(self):
        return all((self.configured, self.checkout_first_order_check, self.exact_three_product_selection,
                    self.maximum_one_unit_per_product, self.non_combining, self.two_hour_expiry,
                    self.atomic_single_redemption)) and self.mode in {"shopify_function", "shopify_native"}


@dataclass(frozen=True)
class PlatformApplicationReceipt:
    """Only a real adapter can produce a platform-confirmed application result."""
    shop: str
    offer_id: str
    cart_reference: str
    status: str  # pending | applied | rejected, based on a fresh platform response
    platform_reference: str


class DiscountPlatformAdapter(Protocol):
    def capabilities(self) -> DiscountCapabilities: ...
    async def inspect_checkout(self, request: PlatformEligibilityRequest) -> ShopifyCheckoutEvidence: ...
    async def request_application(self, instruction: DiscountInstruction) -> PlatformApplicationReceipt: ...


class UnavailableDiscountAdapter:
    def capabilities(self):
        return DiscountCapabilities()

    async def inspect_checkout(self, request):
        raise DiscountConfigurationUnavailable("A verified Shopify discount integration is required")

    async def request_application(self, instruction):
        raise DiscountConfigurationUnavailable("A verified Shopify discount integration is required")


def discount_feature_status(adapter: DiscountPlatformAdapter) -> dict:
    capability = adapter.capabilities()
    return {"available": capability.available, "status": "platform_ready" if capability.available else "not_configured",
            "policy_version": POLICY_VERSION, "applied": False,
            "reason": None if capability.available else DiscountConfigurationUnavailable.code}


async def prepare_discount(offer: GiftOffer, request: PlatformEligibilityRequest, *, now: int,
                           adapter: DiscountPlatformAdapter) -> tuple[DiscountDecision, PlatformApplicationReceipt | None]:
    if not adapter.capabilities().available:
        raise DiscountConfigurationUnavailable("The installation cannot enforce the complete discount policy")
    evidence = await adapter.inspect_checkout(request)
    decision = evaluate_offer(offer, request, evidence, now=now)
    if not decision.eligible:
        return decision, None
    receipt = await adapter.request_application(decision.instruction)
    if (receipt.shop != offer.shop or receipt.offer_id != offer.id or receipt.cart_reference != request.cart_reference
            or receipt.status not in {"pending", "applied", "rejected"} or not receipt.platform_reference):
        raise DiscountContractError("Platform receipt is missing or belongs to another cart/offer/store")
    return decision, receipt
