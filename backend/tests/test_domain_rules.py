import copy
import unittest

from app.domain.catalog import map_shopify_product
from app.domain.fitting import calibrated_cat_harness, fitting_manifest, validate_transform
from app.domain.recommendations import normalize_pet, recommend, revalidate_selection
from app.providers.errors import DomainValidationError


def product(number=1, **changes):
    result = {"id": f"gid://shopify/Product/{number}", "title": "Test harness", "status": "ACTIVE",
              "published": True, "available": True, "price": "20.00", "currency": "USD",
              "categories": ["wear"], "pet_types": ["dog"], "dog_sizes": [],
              "variants": [{"id": f"gid://shopify/ProductVariant/{number}", "available": True, "price": "20.00"}],
              "tryon_enabled": True, "images": [{"url": "https://cdn.shopify.com/product.png"}]}
    result.update(changes)
    return result


PET = {"type": "dog", "age_months": 24, "dog_size": "medium"}


class RecommendationTests(unittest.TestCase):
    def test_published_priority_and_diversity_are_preserved(self):
        rows = [product(7, categories=["wear"]), product(3, categories=["cleanup"]),
                product(1, categories=["toys"]), product(2, categories=["toys"])]
        result = recommend(PET, rows)
        self.assertEqual(result["product_ids"], [rows[2]["id"], rows[1]["id"], rows[0]["id"]])
        self.assertEqual(result["status"], "ready")

    def test_filter_species_size_age_and_availability(self):
        rows = [product(1, pet_types=["cat"]), product(2, dog_sizes=["small"]),
                product(3, max_age_months=12), product(4, published=False),
                product(5, available=False), product(6, excluded_from_gifts=True), product(7)]
        self.assertEqual(recommend(PET, rows)["product_ids"], [rows[-1]["id"]])

    def test_partial_and_empty_results_do_not_invent_products(self):
        self.assertEqual(recommend(PET, [product()])["status"], "partial")
        self.assertEqual(recommend(PET, [product(status="DRAFT")])["status"], "empty")

    def test_revalidate_removes_newly_unavailable_selected_product(self):
        rows = [product(1), product(2)]
        ids = recommend(PET, rows)["product_ids"]
        rows[1]["available"] = False
        self.assertEqual([row["id"] for row in revalidate_selection(ids, rows, PET)], [rows[0]["id"]])

    def test_contact_fields_never_enter_normalized_model_attributes(self):
        profile = {"email": "private@example.invalid", "pet_name": "Private", **PET}
        self.assertEqual(normalize_pet(profile), PET)

    def test_invalid_profile_rejected(self):
        for profile in ({**PET, "age_months": True}, {**PET, "dog_size": "unknown"}, {**PET, "age_months": 481},
                        {"user_pets": []}, {"user_pets": {}}, {"user_pets": [None]}, {"pet_information": []}):
            with self.assertRaises(DomainValidationError):
                normalize_pet(profile)


class MappingTests(unittest.TestCase):
    def test_media_maps_images_and_variant_reference_without_deprecated_fields(self):
        raw = {"id": "gid://shopify/Product/123", "status": "ACTIVE", "onlineStoreUrl": "https://shop.invalid/p",
               "media": {"nodes": [{}, {"image": None}, {"image": {"url": "https://cdn.shopify.com/product.png", "altText": "Product"}}]},
               "variants": {"nodes": [{"id": "gid://shopify/ProductVariant/456", "price": "20", "inventoryPolicy": "CONTINUE",
                                        "media": {"nodes": [{"image": {"url": "https://cdn.shopify.com/variant.png", "altText": "Variant"}}]}}]}}
        mapped = map_shopify_product(raw)
        self.assertEqual(mapped["images"], [{"url": "https://cdn.shopify.com/product.png", "altText": "Product"}])
        self.assertEqual(mapped["variants"][0]["image"], "https://cdn.shopify.com/variant.png")

    def test_empty_current_media_does_not_resurrect_stale_legacy_images(self):
        raw = {"id": "gid://shopify/Product/123", "media": {"nodes": []},
               "images": {"nodes": [{"url": "https://cdn.shopify.com/stale.png"}]},
               "variants": {"nodes": [{"id": "gid://shopify/ProductVariant/456", "price": "20", "media": {"nodes": []},
                                        "image": {"url": "https://cdn.shopify.com/stale-variant.png"}}]}}
        mapped = map_shopify_product(raw)
        self.assertEqual(mapped["images"], [])
        self.assertIsNone(mapped["variants"][0]["image"])

    def test_legacy_offline_snapshot_images_remain_readable(self):
        raw = {"id": "gid://shopify/Product/123", "images": {"nodes": [{"url": "https://cdn.shopify.com/product.png"}]},
               "variants": {"nodes": [{"id": "gid://shopify/ProductVariant/456", "price": "20", "image": {"url": "https://cdn.shopify.com/variant.png"}}]}}
        mapped = map_shopify_product(raw)
        self.assertEqual(mapped["images"][0]["url"], "https://cdn.shopify.com/product.png")
        self.assertEqual(mapped["variants"][0]["image"], "https://cdn.shopify.com/variant.png")

    def test_native_ids_publication_and_sell_when_out_of_stock(self):
        raw = {"id": "gid://shopify/Product/123", "status": "ACTIVE", "onlineStoreUrl": "https://shop.invalid/products/test",
               "variants": {"nodes": [{"id": "gid://shopify/ProductVariant/456", "price": "0.10", "inventoryQuantity": 0,
                                          "inventoryPolicy": "CONTINUE", "inventoryItem": {"tracked": True}}]}, "tags": ["pet:dog"]}
        mapped = map_shopify_product(raw)
        self.assertEqual(mapped["id"], raw["id"])
        self.assertEqual(mapped["variants"][0]["id"], "gid://shopify/ProductVariant/456")
        self.assertTrue(mapped["available"])
        self.assertEqual(mapped["price"], "0.10")
        raw["onlineStoreUrl"] = None
        self.assertFalse(map_shopify_product(raw)["available"])

    def test_numeric_woocommerce_ids_are_rejected(self):
        with self.assertRaises(DomainValidationError):
            map_shopify_product({"id": 107})


class FittingTests(unittest.TestCase):
    def test_archived_calibrated_fixture_produces_finite_manifest(self):
        row = product(fitting=calibrated_cat_harness("https://cdn.shopify.com/cat.glb", "https://cdn.shopify.com/harness.glb"))
        manifest = fitting_manifest(row)
        self.assertEqual(manifest["wear_region"], "chest_back")
        for scale in manifest["garment_transform"]["scale"]:
            self.assertAlmostEqual(scale, 1, places=6)

    def fixture(self):
        return product(fitting={"pet_id": "toon-cat", "pet_asset_url": "https://cdn.shopify.com/cat.glb",
                                "garment_asset_url": "https://cdn.shopify.com/harness.glb",
                                "wearing": {"mode": "harness"},
                                "landmarks": {"shoulder": [0, 0.5, 0], "neck_base": [0, 0.5, 0.5],
                                              "mid_back": [0, 0.5, 0], "front_left": [-0.5, 0, 0], "front_right": [0.5, 0, 0]},
                                "garment_profile": {"wear_region": "chest_back", "anchor": "shoulder",
                                                    "reference_chest_width": 1, "reference_torso_span": 0.5,
                                                    "forward_axis": "+Z", "up_axis": "+Y"}})

    def test_known_frame_returns_identity_rotation(self):
        manifest = fitting_manifest(self.fixture())
        self.assertEqual(manifest["garment_transform"]["quaternion"], [0, 0, 0, 1])
        self.assertEqual(manifest["garment_transform"]["scale"], [1, 1, 1])

    def test_manual_revision_requires_matching_asset_fingerprint(self):
        row = self.fixture()
        row["fitting"].update(asset_fingerprint="a" * 64, manual={"enabled": True, "asset_fingerprint": "b" * 64,
                             "transform": {"position": [0, 0, 0], "quaternion": [0, 0, 0, 1], "scale": [1, 1, 1]}})
        with self.assertRaises(DomainValidationError):
            fitting_manifest(row)
        row["fitting"]["manual"]["asset_fingerprint"] = "a" * 64
        self.assertEqual(fitting_manifest(row)["source"], "manual")

    def test_degenerate_or_uncalibrated_geometry_rejected(self):
        row = self.fixture()
        row["fitting"]["landmarks"]["neck_base"] = row["fitting"]["landmarks"]["mid_back"]
        with self.assertRaises(DomainValidationError):
            fitting_manifest(row)
        with self.assertRaises(DomainValidationError):
            validate_transform({"position": [0, 0, 0], "quaternion": [0, 0, 0, 0], "scale": [1, 1, 1]})
