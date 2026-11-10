"""Social profile API tests for the independent lifetime-profile module."""
import io
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import identity
from app.main import create_app
from app.social_profile_api import SocialProfile, router

from .support import build_settings, make_client, mobile_login


@contextmanager
def social_client(settings):
    app = create_app(settings)
    app.include_router(router)
    with TestClient(app) as client:
        SocialProfile.__table__.create(client.app.state.engine, checkfirst=True)
        yield client


def _png(color="blue", size=(64, 48)):
    output = io.BytesIO()
    Image.new("RGB", size, color).save(output, "PNG")
    return output.getvalue()


def test_profile_requires_verified_bearer_and_defaults_to_incomplete(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        assert client.get("/mobile/v1/social-profile").status_code == 401
        _tokens, headers = mobile_login(client, settings, "social@example.com")
        body = client.get("/mobile/v1/social-profile", headers=headers).json()
        assert body["user_id"]
        assert body["display_name"] is None
        assert body["profile_completed"] is False
        assert set(body["missing"]) == {"display_name", "avatar"}
        assert body["avatar"] == {"kind": "none", "default_key": None, "public_key": None,
                                  "available": False, "updated_at": None}
        assert "paw" in body["default_avatar_keys"]


def test_default_avatar_must_be_explicit_and_completes_profile(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        _tokens, headers = mobile_login(client, settings, "default-avatar@example.com")
        name_only = client.patch("/mobile/v1/social-profile", headers=headers,
                                 json={"display_name": "  小  金  "})
        assert name_only.status_code == 200, name_only.text
        assert name_only.json()["display_name"] == "小 金"
        assert name_only.json()["profile_completed"] is False
        assert name_only.json()["missing"] == ["avatar"]

        bad = client.patch("/mobile/v1/social-profile", headers=headers,
                           json={"default_avatar_key": "unknown"})
        assert bad.status_code == 422 and bad.json()["detail"] == "invalid_default_avatar_key"

        chosen = client.patch("/mobile/v1/social-profile", headers=headers,
                              json={"default_avatar_key": "paw"})
        assert chosen.status_code == 200
        body = chosen.json()
        assert body["profile_completed"] is True and body["missing"] == []
        assert body["avatar"]["kind"] == "default"
        assert body["avatar"]["default_key"] == "paw"
        assert body["avatar"]["public_key"] == "default:paw"
        assert body["avatar"]["available"] is True
        # Default avatars are client-rendered keys, not server image bytes.
        image = client.get("/mobile/v1/social-profile/avatar", headers=headers)
        assert image.status_code == 404
        assert image.headers["x-default-avatar-key"] == "paw"


def test_patch_validation_and_no_change_contract(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        _tokens, headers = mobile_login(client, settings, "patch@example.com")
        assert client.patch("/mobile/v1/social-profile", headers=headers, json={}).status_code == 422
        assert client.patch("/mobile/v1/social-profile", headers=headers,
                            json={"display_name": "  "}).status_code == 422
        assert client.patch("/mobile/v1/social-profile", headers=headers,
                            json={"display_name": "x" * 41}).status_code == 422
        assert client.patch("/mobile/v1/social-profile", headers=headers,
                            json={"display_name": "ok", "unknown": 1}).status_code == 422
        # No mutations on rejected requests.
        body = client.get("/mobile/v1/social-profile", headers=headers).json()
        assert body["display_name"] is None and body["profile_completed"] is False


def test_upload_avatar_normalizes_strips_exif_and_is_owner_only(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        _tokens, headers = mobile_login(client, settings, "avatar-owner@example.com")
        client.patch("/mobile/v1/social-profile", headers=headers, json={"display_name": "Avatar Owner"})
        upload = client.post("/mobile/v1/social-profile/avatar", headers=headers,
                             files={"file": ("avatar.png", _png("orange", (1024, 768)), "image/png")})
        assert upload.status_code == 201, upload.text
        body = upload.json()
        assert body["profile_completed"] is True
        assert body["avatar"]["kind"] == "upload"
        assert body["avatar"]["available"] is True
        assert body["avatar"]["public_key"].startswith("social:")
        assert "path" not in body["avatar"] and "email" not in body

        image_response = client.get("/mobile/v1/social-profile/avatar", headers=headers)
        assert image_response.status_code == 200
        assert image_response.headers["content-type"].startswith("image/jpeg")
        with Image.open(io.BytesIO(image_response.content)) as image:
            assert image.format == "JPEG"
            assert max(image.size) <= 512
            assert len(image.getexif()) == 0

        # A second account sees only its own profile/avatar, never the owner's bytes.
        _tokens2, headers2 = mobile_login(client, settings, "avatar-other@example.com")
        other = client.get("/mobile/v1/social-profile", headers=headers2).json()
        assert other["user_id"] != body["user_id"]
        assert other["avatar"]["kind"] == "none"
        assert client.get("/mobile/v1/social-profile/avatar", headers=headers2).status_code == 404


def test_upload_limits_type_mismatch_and_large_file(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        _tokens, headers = mobile_login(client, settings, "avatar-limits@example.com")
        wrong_mime = client.post("/mobile/v1/social-profile/avatar", headers=headers,
                                 files={"file": ("avatar.png", _png(), "image/jpeg")})
        assert wrong_mime.status_code == 415
        bad_type = client.post("/mobile/v1/social-profile/avatar", headers=headers,
                               files={"file": ("avatar.txt", b"not an image", "text/plain")})
        assert bad_type.status_code == 415
        too_large = client.post("/mobile/v1/social-profile/avatar", headers=headers,
                                files={"file": ("large.jpg", b"x" * (5 * 1024 * 1024 + 1), "image/jpeg")})
        assert too_large.status_code == 413
        # No URL field is accepted; malformed multipart yields 422.
        assert client.post("/mobile/v1/social-profile/avatar", headers=headers,
                           json={"url": "https://evil.test/avatar.jpg"}).status_code == 422


def test_unverified_token_cannot_read_or_write_social_profile(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        sessions = client.app.state.sessions
        user = identity.get_or_create_user(sessions, "unverified-social@example.com",
                                           "unverified-social@example.com")
        tokens = identity.issue_mobile_tokens(sessions, settings, user.id, settings.local_shop)
        headers = {"Authorization": "Bearer " + tokens["access_token"]}
        assert client.get("/mobile/v1/social-profile", headers=headers).status_code == 401
        assert client.patch("/mobile/v1/social-profile", headers=headers,
                            json={"display_name": "Nope"}).status_code == 401


# ---------------------------------------------------------------------------
# Controlled authenticated avatar resolver / social DTO fields

def _verified(client, settings, email, pet_name="Milo"):
    from .support import claim_website_session, issue_guest

    headers, _ = issue_guest(client, email=email,
                             profile={"type": "dog", "age_months": 12,
                                      "dog_size": "small", "name": pet_name})
    claim_website_session(client, settings, headers, email)
    _tokens, mobile = mobile_login(client, settings, email)
    me = client.get("/mobile/v1/me", headers=mobile).json()
    return {"mobile": mobile, "me": me}


def _enable(client, user, lat=31.23, lon=121.47, radius=5):
    response = client.post("/mobile/v1/discovery", headers=user["mobile"],
                           json={"enabled": True,
                                 "region": {"lat": lat, "lon": lon, "label": "QA"},
                                 "radius_km": radius})
    assert response.status_code == 202, response.text


def _set_social(client, user, name="Bob", default_key=None):
    payload = {"display_name": name}
    if default_key:
        payload["default_avatar_key"] = default_key
    response = client.patch("/mobile/v1/social-profile", headers=user["mobile"], json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def _upload_social(client, user):
    response = client.post("/mobile/v1/social-profile/avatar", headers=user["mobile"],
                           files={"file": ("bob.png", _png("green", (320, 320)), "image/png")})
    assert response.status_code == 201, response.text
    return response.json()


def test_avatar_resolver_is_relationship_gated_not_user_id_or_public_key(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        alice = _verified(client, settings, "resolver-a@example.com", "A")
        bob = _verified(client, settings, "resolver-b@example.com", "B")
        _set_social(client, bob, "Bob", "paw")
        bob_ref = bob["me"]["public_ref"]

        # No accepted contact and no discovery: no access, and user_id/public_key are not keys.
        assert client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"]).status_code == 404
        assert client.get(f"/mobile/v1/users/{bob['me']['user_id']}/avatar", headers=alice["mobile"]).status_code == 404
        assert client.get("/mobile/v1/users/social:deadbeef/avatar", headers=alice["mobile"]).status_code == 404

        _enable(client, alice)
        _enable(client, bob)
        default = client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"])
        assert default.status_code == 404
        assert default.headers["x-default-avatar-key"] == "paw"

        uploaded = _upload_social(client, bob)
        assert uploaded["avatar"]["kind"] == "upload"
        image = client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"])
        assert image.status_code == 200
        assert image.headers["content-type"].startswith("image/jpeg")

        nearby = client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()["items"]
        item = next(entry for entry in nearby if entry["public_ref"] == bob_ref)
        assert item["social_display_name"] == "Bob"
        assert item["social_avatar"]["kind"] == "upload"
        assert item["social_avatar"]["authenticated_path"] == f"/mobile/v1/users/{bob_ref}/avatar"
        assert item["pet"]["avatar_url"] is None
        assert "resolver-b@example.com" not in str(item)

        # Accepted contact grants access even after discovery is turned off.
        created = client.post("/mobile/v1/contacts/requests", headers=alice["mobile"],
                              json={"target_public_ref": bob_ref})
        assert created.status_code in (200, 201)
        incoming = client.get("/mobile/v1/contacts/requests?direction=incoming",
                              headers=bob["mobile"]).json()["items"]
        request_id = incoming[0]["request_id"]
        accepted = client.post(f"/mobile/v1/contacts/requests/{request_id}/accept",
                               headers=bob["mobile"])
        assert accepted.status_code == 200
        client.post("/mobile/v1/discovery", headers=alice["mobile"], json={"enabled": False})
        client.post("/mobile/v1/discovery", headers=bob["mobile"], json={"enabled": False})
        assert client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"]).status_code == 200
        contacts = client.get("/mobile/v1/contacts", headers=alice["mobile"]).json()["items"]
        assert contacts[0]["social_display_name"] == "Bob"
        assert contacts[0]["social_avatar"]["kind"] == "upload"

        # Blocking wins over contact and is denied in both directions.
        assert client.post("/mobile/v1/blocks", headers=bob["mobile"],
                           json={"target_public_ref": alice["me"]["public_ref"]}).status_code == 201
        blocked = client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"])
        assert blocked.status_code == 403
        assert client.get(f"/mobile/v1/users/{alice['me']['public_ref']}/avatar",
                          headers=bob["mobile"]).status_code == 403


def test_avatar_resolver_requires_mutual_discovery_and_unexpired_range(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        alice = _verified(client, settings, "range-a@example.com", "A")
        bob = _verified(client, settings, "range-b@example.com", "B")
        _set_social(client, bob, "Range Bob", "paw")
        bob_ref = bob["me"]["public_ref"]
        _enable(client, alice, radius=5)
        _enable(client, bob, radius=5)
        assert client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"]).status_code == 404  # default key
        # A upload so a denied/allowed result is distinguishable by HTTP 200.
        _upload_social(client, bob)
        assert client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"]).status_code == 200

        # Target radius too small for the coarse-grid distance: no mutual visibility.
        _enable(client, bob, lat=31.26, radius=1)
        denied = client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"])
        assert denied.status_code == 404
        assert "x-default-avatar-key" not in denied.headers
        nearby = client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()["items"]
        if nearby:
            assert "social_display_name" not in nearby[0]

        # Expired target discovery is not visible.
        _enable(client, bob, radius=5)
        with client.app.state.sessions() as db:
            from app.models import DiscoveryProfile
            row = db.query(DiscoveryProfile).filter_by(user_id=bob["me"]["user_id"]).one()
            row.expires_at = 1.0
            db.commit()
        assert client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"]).status_code == 404

        # Restore mutual visibility, then disable the viewer: still denied.
        _enable(client, bob, radius=5)
        client.post("/mobile/v1/discovery", headers=alice["mobile"], json={"enabled": False})
        assert client.get(f"/mobile/v1/users/{bob_ref}/avatar", headers=alice["mobile"]).status_code == 404


def test_same_image_two_users_do_not_share_avatar_storage_key(tmp_path):
    settings = build_settings(tmp_path)
    with social_client(settings) as client:
        _t1, headers_a = mobile_login(client, settings, "same-image-a@example.com")
        _t2, headers_b = mobile_login(client, settings, "same-image-b@example.com")
        png = _png("purple", (300, 300))
        for headers, name in ((headers_a, "a"), (headers_b, "b")):
            client.patch("/mobile/v1/social-profile", headers=headers,
                         json={"display_name": "Same " + name})
            response = client.post("/mobile/v1/social-profile/avatar", headers=headers,
                                   files={"file": ("same.png", png, "image/png")})
            assert response.status_code == 201, response.text
        first_b = client.get("/mobile/v1/social-profile/avatar", headers=headers_b)
        assert first_b.status_code == 200
        original_b = first_b.content

        # A replaces its avatar with a different image. B's file must remain readable.
        replacement = _png("orange", (320, 320))
        replaced = client.post("/mobile/v1/social-profile/avatar", headers=headers_a,
                               files={"file": ("replacement.png", replacement, "image/png")})
        assert replaced.status_code == 201, replaced.text
        second_b = client.get("/mobile/v1/social-profile/avatar", headers=headers_b)
        assert second_b.status_code == 200
        assert second_b.content == original_b

        with client.app.state.sessions() as db:
            from app.social_profile_api import SocialProfile
            rows = db.query(SocialProfile).all()
            keys = {row.avatar_storage_key for row in rows}
            shas = {row.avatar_sha256 for row in rows}
            assert None not in keys and len(keys) == 2
            assert len(shas) == 2  # images differ after A replacement
        # Default avatar JSON response has a real body/Content-Length (not 0).
        client.patch("/mobile/v1/social-profile", headers=headers_b,
                     json={"default_avatar_key": "paw"})
        default = client.get("/mobile/v1/social-profile/avatar", headers=headers_b)
        assert default.status_code == 404
        assert int(default.headers["content-length"]) > 0
        assert default.json()["detail"] == "avatar_default_selected"
