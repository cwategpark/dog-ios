import asyncio
from dataclasses import replace
from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.discounts import (
    DealClientRequest, DecisionReason, DiscountCapabilities, DiscountConfigurationUnavailable,
    DiscountContractError, FirstOrderStatus, PlatformApplicationReceipt, SelectedVariant,
    ShopifyCartLine, ShopifyCheckoutEvidence, UnavailableDiscountAdapter, build_offer,
    discount_feature_status, eligibility_request, evaluate_offer, prepare_discount, unrounded_estimate,
)


NOW = 100_000
SHOP = "example.myshopify.com"
OWNER = "guest-owner"


def scenario(currency="USD", price="10.05"):
    selected = tuple(SelectedVariant(f"gid://shopify/Product/{i}", f"gid://shopify/ProductVariant/{100 + i}") for i in (1, 2, 3))
    offer = build_offer(offer_id="a" * 32, shop=SHOP, owner_id=OWNER, selected=selected,
                        recommended_product_ids=tuple(item.product_id for item in selected), now=NOW)
    request = eligibility_request(offer, DealClientRequest(offer_id=offer.id, cart_reference="bound_cart_123"),
                                  authenticated_owner_id=OWNER, authenticated_shop=SHOP)
    lines = tuple(ShopifyCartLine(f"gid://shopify/CartLine/{index}", item.product_id, item.variant_id,
                                  1, True, Decimal(price), currency) for index, item in enumerate(selected))
    evidence = ShopifyCheckoutEvidence(SHOP, OWNER, request.cart_reference, "platform-verified-buyer",
                                       FirstOrderStatus.CONFIRMED_ELIGIBLE, NOW, True, lines, False, currency)
    return offer, request, evidence


def test_three_distinct_products_and_chosen_variants_from_trusted_recommendation():
    offer, _, _ = scenario()
    with pytest.raises(DiscountContractError):
        replace(offer, selected=(offer.selected[0], offer.selected[0], offer.selected[2]))
    with pytest.raises(DiscountContractError):
        build_offer(offer_id=offer.id, shop=SHOP, owner_id=OWNER, selected=offer.selected,
                    recommended_product_ids=("gid://shopify/Product/9", "gid://shopify/Product/2", "gid://shopify/Product/3"), now=NOW)
    with pytest.raises(DiscountContractError):
        replace(offer, expires_at=NOW + 7201)


@pytest.mark.parametrize("extra", [{"email": "claimed@example.invalid"}, {"first_order": True},
                                   {"is_eligible": True}, {"discount_percentage": 100}, {"price": "0"}])
def test_browser_cannot_claim_identity_eligibility_or_price(extra):
    with pytest.raises(ValidationError):
        DealClientRequest(offer_id="a" * 32, cart_reference="bound_cart_123", **extra)


def test_missing_or_rejected_shopify_first_order_evidence_denies_discount():
    offer, request, evidence = scenario()
    for state, reason in ((FirstOrderStatus.UNKNOWN, DecisionReason.FIRST_ORDER_UNKNOWN),
                          (FirstOrderStatus.CONFIRMED_INELIGIBLE, DecisionReason.NOT_FIRST_ORDER)):
        decision = evaluate_offer(offer, request, replace(evidence, first_order_status=state), now=NOW)
        assert not decision.eligible and decision.reason == reason
    assert evaluate_offer(offer, request, replace(evidence, buyer_reference=None), now=NOW).reason == DecisionReason.FIRST_ORDER_UNKNOWN
    # A submitted boolean is not an internal, verified FirstOrderStatus enum.
    assert evaluate_offer(offer, request, replace(evidence, first_order_status=True), now=NOW).reason == DecisionReason.FIRST_ORDER_UNKNOWN


def test_expiry_is_two_hours_and_confirmation_must_be_fresh():
    offer, request, evidence = scenario()
    assert evaluate_offer(offer, request, replace(evidence, confirmed_at=offer.expires_at - 1), now=offer.expires_at - 1).eligible
    assert evaluate_offer(offer, request, replace(evidence, confirmed_at=offer.expires_at), now=offer.expires_at).reason == DecisionReason.EXPIRED
    assert evaluate_offer(offer, request, evidence, now=NOW - 1).reason == DecisionReason.NOT_STARTED
    assert evaluate_offer(offer, request, replace(evidence, confirmed_at=NOW - 61), now=NOW).reason == DecisionReason.STALE_CHECKOUT


def test_scopes_and_cart_binding_are_checked():
    offer, request, evidence = scenario()
    for changed, reason in ((replace(evidence, owner_id="other"), DecisionReason.OWNER_MISMATCH),
                            (replace(evidence, shop="other.myshopify.com"), DecisionReason.SHOP_MISMATCH),
                            (replace(evidence, cart_reference="other_cart"), DecisionReason.CART_MISMATCH),
                            (replace(evidence, cart_bound_to_owner=False), DecisionReason.CART_MISMATCH)):
        assert evaluate_offer(offer, request, changed, now=NOW).reason == reason
    with pytest.raises(DiscountContractError):
        eligibility_request(offer, DealClientRequest(offer_id=offer.id, cart_reference=request.cart_reference),
                            authenticated_owner_id="other", authenticated_shop=SHOP)


def test_requires_all_selected_products_with_available_chosen_variants():
    offer, request, evidence = scenario()
    assert evaluate_offer(offer, request, replace(evidence, lines=evidence.lines[:2]), now=NOW).reason == DecisionReason.BUNDLE_INCOMPLETE
    lines = (*evidence.lines[:2], replace(evidence.lines[2], available=False))
    assert evaluate_offer(offer, request, replace(evidence, lines=lines), now=NOW).reason == DecisionReason.VARIANT_UNAVAILABLE
    wrong_variant = replace(evidence.lines[2], variant_id="gid://shopify/ProductVariant/999")
    assert evaluate_offer(offer, request, replace(evidence, lines=(*evidence.lines[:2], wrong_variant)), now=NOW).reason == DecisionReason.BUNDLE_INCOMPLETE


def test_quantity_cap_applies_once_per_selected_product_even_with_split_lines():
    offer, request, evidence = scenario()
    more = replace(evidence.lines[0], id="gid://shopify/CartLine/split", quantity=10)
    evidence = replace(evidence, lines=(*tuple(replace(line, quantity=4) for line in evidence.lines), more))
    decision = evaluate_offer(offer, request, evidence, now=NOW)
    assert decision.eligible
    assert len(decision.instruction.targets) == 3
    assert sum(target.quantity for target in decision.instruction.targets) == 3
    assert decision.instruction.percentage == Decimal("20")
    assert decision.instruction.maximum_redemptions == 1
    assert decision.instruction.require_first_order_revalidation
    assert not decision.instruction.combines_with_shipping_discounts
    assert not decision.instruction.combines_with_product_discounts
    assert not decision.instruction.combines_with_order_discounts


def test_existing_discount_or_currency_mismatch_is_not_silently_combined():
    offer, request, evidence = scenario()
    assert evaluate_offer(offer, request, replace(evidence, other_discount_present=True), now=NOW).reason == DecisionReason.OTHER_DISCOUNT
    changed = replace(evidence.lines[2], currency="JPY")
    assert evaluate_offer(offer, request, replace(evidence, lines=(*evidence.lines[:2], changed)), now=NOW).reason == DecisionReason.CURRENCY_MISMATCH


@pytest.mark.parametrize("currency,unit,total,discount", [("USD", "10.05", "30.15", "6.03"),
                                                         ("JPY", "11", "33", "6.6"),
                                                         ("KWD", "1.001", "3.003", "0.6006")])
def test_decimal_estimates_are_unrounded_and_never_claim_final_shopify_allocation(currency, unit, total, discount):
    offer, request, evidence = scenario(currency, unit)
    decision = evaluate_offer(offer, request, evidence, now=NOW)
    estimate = unrounded_estimate(decision.instruction, evidence)
    assert estimate.base_amount == Decimal(total)
    assert estimate.discount_amount == Decimal(discount)
    assert estimate.final is False and estimate.rounding_authority == "shopify"


@pytest.mark.parametrize("bad", [1.1, "1.1", Decimal("NaN"), Decimal("Infinity"), Decimal("-1")])
def test_money_rejects_floats_and_invalid_decimal_values(bad):
    _, _, evidence = scenario()
    with pytest.raises(DiscountContractError):
        replace(evidence.lines[0], unit_price=bad)


def test_unconfigured_adapter_is_503_and_does_not_claim_effective_discount():
    offer, request, _ = scenario()
    adapter = UnavailableDiscountAdapter()
    assert discount_feature_status(adapter) == {"available": False, "status": "not_configured", "policy_version": offer.policy_version,
                                               "applied": False, "reason": "discount_platform_not_configured"}
    with pytest.raises(DiscountConfigurationUnavailable) as caught:
        asyncio.run(prepare_discount(offer, request, now=NOW, adapter=adapter))
    assert caught.value.status_code == 503


class ConfirmedTestAdapter:
    """Test double only; no production adapter is enabled by these tests."""
    def __init__(self, evidence, receipt_status="pending"):
        self.evidence = evidence
        self.receipt_status = receipt_status
        self.application_calls = []

    def capabilities(self):
        return DiscountCapabilities(True, True, True, True, True, True, True, "shopify_function")

    async def inspect_checkout(self, request):
        return self.evidence

    async def request_application(self, instruction):
        self.application_calls.append(instruction)
        return PlatformApplicationReceipt(instruction.shop, instruction.offer_id, instruction.cart_reference,
                                          self.receipt_status, "test-platform-reference")


def test_real_adapter_result_is_required_before_any_application_claim():
    offer, request, evidence = scenario()
    adapter = ConfirmedTestAdapter(evidence)
    decision, receipt = asyncio.run(prepare_discount(offer, request, now=NOW, adapter=adapter))
    assert decision.eligible and receipt.status == "pending"
    assert len(adapter.application_calls) == 1
    assert discount_feature_status(adapter)["applied"] is False
    denied = ConfirmedTestAdapter(replace(evidence, first_order_status=FirstOrderStatus.CONFIRMED_INELIGIBLE))
    decision, receipt = asyncio.run(prepare_discount(offer, request, now=NOW, adapter=denied))
    assert not decision.eligible and receipt is None and denied.application_calls == []


def test_partial_capability_cannot_enable_inexact_native_discount():
    adapter = ConfirmedTestAdapter(None)
    adapter.capabilities = lambda: DiscountCapabilities(True, True, True, False, True, True, True, "shopify_native")
    offer, request, _ = scenario()
    with pytest.raises(DiscountConfigurationUnavailable):
        asyncio.run(prepare_discount(offer, request, now=NOW, adapter=adapter))


def test_redemption_scope_is_shared_across_offers_for_same_verified_buyer():
    offer, request, evidence = scenario()
    first = evaluate_offer(offer, request, evidence, now=NOW).instruction
    other_offer = replace(offer, id="b" * 32, owner_id="another-guest-session")
    other_request = replace(request, offer_id=other_offer.id, owner_id=other_offer.owner_id)
    other_evidence = replace(evidence, owner_id=other_offer.owner_id)
    second = evaluate_offer(other_offer, other_request, other_evidence, now=NOW).instruction
    assert first.redemption_scope == second.redemption_scope
    changed_buyer = replace(other_evidence, buyer_reference="different-platform-verified-buyer")
    third = evaluate_offer(other_offer, other_request, changed_buyer, now=NOW).instruction
    assert first.redemption_scope != third.redemption_scope
