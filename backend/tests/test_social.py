import time

import pytest
from sqlalchemy import select

from app.models import Contact, ContactMessage, DiscoveryProfile

from .support import (build_settings, claim_website_session, issue_guest, make_client,
                      mobile_login)


def verified_user(client, settings, email, pet_name="Milo"):
    headers, _ = issue_guest(client, email=email,
                             profile={"type": "dog", "age_months": 12, "dog_size": "small", "name": pet_name})
    claim_website_session(client, settings, headers, email)
    tokens, mobile = mobile_login(client, settings, email)
    me = client.get("/mobile/v1/me", headers=mobile).json()
    return {"headers": headers, "mobile": mobile, "me": me, "tokens": tokens}


def enable(client, user, lat=31.23, lon=121.47, radius=5):
    response = client.post("/mobile/v1/discovery", headers=user["mobile"],
                           json={"enabled": True, "region": {"lat": lat, "lon": lon, "label": "Shanghai"}, "radius_km": radius})
    assert response.status_code == 202, response.text
    return response.json()


def test_discovery_defaults_off_and_validates_region(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user = verified_user(client, settings, "a@example.com")
        assert client.get("/mobile/v1/discovery", headers=user["mobile"]).json()["enabled"] is False
        assert client.get("/mobile/v1/nearby", headers=user["mobile"]).status_code == 409
        assert client.post("/mobile/v1/discovery", headers=user["mobile"], json={"enabled": True}).status_code == 422
        assert client.post("/mobile/v1/discovery", headers=user["mobile"],
                           json={"enabled": True, "region": {"lat": 31.2, "lon": 121.4}, "radius_km": 99}).status_code == 422


def test_nearby_exposes_only_coarse_public_data(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "alice@example.com", "Milo")
        bob = verified_user(client, settings, "bob@example.com", "Afu")
        enable(client, alice)
        enable(client, bob)
        response = client.get("/mobile/v1/nearby", headers=alice["mobile"])
        assert response.status_code == 200
        payload = response.json()
        text = response.text
        assert "alice@example.com" not in text and "bob@example.com" not in text
        assert len(payload["items"]) == 1
        item = payload["items"][0]
        assert item["public_ref"] == bob["me"]["public_ref"]
        assert item["public_ref"] != bob["me"]["user_id"]
        assert set(item["pet"].keys()) == {"name", "species", "breed", "age_months", "avatar_url"}
        assert item["pet"]["name"] == "Afu"
        assert set(item["coarse_region"].keys()) == {"grid", "label"}
        assert item["distance_bucket"] in {"lt_1km", "1_3km", "3_10km", "10_25km"}
        assert "lat" not in item["coarse_region"] and "lon" not in item["coarse_region"]
        grid_x, grid_y = item["coarse_region"]["grid"].split(":")
        assert int(grid_x) == int(31.23 // 0.05) and int(grid_y) == int(121.47 // 0.05)


def test_nearby_uses_saved_region_not_arbitrary_query_center(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "alice2@example.com")
        bob = verified_user(client, settings, "bob2@example.com")
        enable(client, alice)
        enable(client, bob, lat=31.235, lon=121.475)
        baseline = client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()
        spoofed = client.get("/mobile/v1/nearby?lat=0&lon=0", headers=alice["mobile"]).json()
        assert len(baseline["items"]) == 1
        assert [item["public_ref"] for item in spoofed["items"]] == [item["public_ref"] for item in baseline["items"]]


def test_expired_or_disabled_discovery_is_invisible(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "alice3@example.com")
        bob = verified_user(client, settings, "bob3@example.com")
        enable(client, alice)
        enable(client, bob)
        with client.app.state.sessions() as db:
            row = db.scalar(select(DiscoveryProfile).where(DiscoveryProfile.user_id == bob["me"]["user_id"]))
            row.expires_at = time.time() - 1
            db.commit()
        assert client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()["items"] == []
        client.post("/mobile/v1/discovery", headers=bob["mobile"], json={"enabled": False})
        assert client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()["items"] == []


def test_contact_request_accept_message_and_blocking(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "alice4@example.com", "Milo")
        bob = verified_user(client, settings, "bob4@example.com", "Afu")
        enable(client, alice)
        enable(client, bob)
        target = client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()["items"][0]["public_ref"]

        created = client.post("/mobile/v1/contacts/requests", headers=alice["mobile"],
                              json={"target_public_ref": target, "message": "Hi! 想一起遛狗"})
        assert created.status_code == 201, created.text
        repeat = client.post("/mobile/v1/contacts/requests", headers=alice["mobile"],
                             json={"target_public_ref": target, "message": "Hi! 想一起遛狗"})
        assert repeat.status_code == 200 and repeat.json()["request_id"] == created.json()["request_id"]

        incoming = client.get("/mobile/v1/contacts/requests?direction=incoming", headers=bob["mobile"]).json()["items"]
        assert len(incoming) == 1 and incoming[0]["user_public_ref"] == alice["me"]["public_ref"]
        request_id = incoming[0]["request_id"]
        # no accepted contact yet: messaging with an arbitrary id is refused
        pre = client.post("/mobile/v1/messages", headers=alice["mobile"],
                          json={"contact_id": request_id, "body": "hi", "client_id": "pre-1"})
        assert pre.status_code == 404

        accepted = client.post(f"/mobile/v1/contacts/requests/{request_id}/accept", headers=bob["mobile"])
        assert accepted.status_code == 200 and accepted.json()["status"] == "accepted"
        contact_id = accepted.json()["contact_id"]
        contacts = client.get("/mobile/v1/contacts", headers=alice["mobile"]).json()["items"]
        assert contacts and contacts[0]["contact_id"] == contact_id

        first = client.post("/mobile/v1/messages", headers=alice["mobile"],
                            json={"contact_id": contact_id, "body": "你好", "client_id": "client-1"})
        assert first.status_code == 201
        duplicate = client.post("/mobile/v1/messages", headers=alice["mobile"],
                                json={"contact_id": contact_id, "body": "你好", "client_id": "client-1"})
        assert duplicate.status_code == 200 and duplicate.json()["message_id"] == first.json()["message_id"]
        conflict = client.post("/mobile/v1/messages", headers=alice["mobile"],
                               json={"contact_id": contact_id, "body": "改过内容", "client_id": "client-1"})
        assert conflict.status_code == 409

        for index in range(3):
            client.post("/mobile/v1/messages", headers=bob["mobile"],
                        json={"contact_id": contact_id, "body": f"reply-{index}", "client_id": f"bob-{index}"})
        page = client.get(f"/mobile/v1/messages?contact_id={contact_id}&limit=2", headers=alice["mobile"]).json()
        assert len(page["items"]) == 2 and page["next_before"] is not None
        older = client.get(f"/mobile/v1/messages?contact_id={contact_id}&limit=2&before={page['next_before']}",
                           headers=alice["mobile"]).json()
        assert older["items"]

        blocked = client.post("/mobile/v1/blocks", headers=bob["mobile"],
                              json={"target_public_ref": alice["me"]["public_ref"]})
        assert blocked.status_code == 201
        assert client.post("/mobile/v1/messages", headers=alice["mobile"],
                           json={"contact_id": contact_id, "body": "blocked?", "client_id": "after-block"}).status_code == 403
        assert client.get("/mobile/v1/contacts", headers=alice["mobile"]).json()["items"] == []
        assert client.get("/mobile/v1/nearby", headers=alice["mobile"]).json()["items"] == []


def test_block_blocks_contact_requests_too(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "alice5@example.com")
        bob = verified_user(client, settings, "bob5@example.com")
        client.post("/mobile/v1/blocks", headers=alice["mobile"],
                    json={"target_public_ref": bob["me"]["public_ref"]})
        response = client.post("/mobile/v1/contacts/requests", headers=bob["mobile"],
                               json={"target_public_ref": alice["me"]["public_ref"]})
        assert response.status_code == 403


def test_messages_persist_across_application_restart(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "alice6@example.com")
        bob = verified_user(client, settings, "bob6@example.com")
        request = client.post("/mobile/v1/contacts/requests", headers=alice["mobile"],
                             json={"target_public_ref": bob["me"]["public_ref"]})
        incoming = client.get("/mobile/v1/contacts/requests?direction=incoming", headers=bob["mobile"]).json()["items"]
        contact_id = client.post(f"/mobile/v1/contacts/requests/{incoming[0]['request_id']}/accept",
                                 headers=bob["mobile"]).json()["contact_id"]
        for index in range(2):
            assert client.post("/mobile/v1/messages", headers=alice["mobile"],
                               json={"contact_id": contact_id, "body": f"persist-{index}", "client_id": f"p-{index}"}).status_code == 201
        contact_id_for_restart = contact_id
    with make_client(settings) as client2:
        _tokens, mobile = mobile_login(client2, settings, "alice6@example.com")
        items = client2.get(f"/mobile/v1/messages?contact_id={contact_id_for_restart}", headers=mobile).json()["items"]
        assert {item["body"] for item in items} == {"persist-0", "persist-1"}


def test_message_pagination_uses_composite_cursor_for_same_second_messages(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "page-a@example.com", "Milo")
        bob = verified_user(client, settings, "page-b@example.com", "Afu")
        request = client.post("/mobile/v1/contacts/requests", headers=alice["mobile"],
                             json={"target_public_ref": bob["me"]["public_ref"]})
        incoming = client.get("/mobile/v1/contacts/requests?direction=incoming", headers=bob["mobile"]).json()["items"]
        contact_id = client.post(f"/mobile/v1/contacts/requests/{incoming[0]['request_id']}/accept",
                                 headers=bob["mobile"]).json()["contact_id"]
        for index in range(5):
            assert client.post("/mobile/v1/messages", headers=alice["mobile"],
                               json={"contact_id": contact_id, "body": f"same-{index}", "client_id": f"s-{index}"}).status_code == 201
        with client.app.state.sessions() as db:
            from app.models import ContactMessage
            rows = db.scalars(select(ContactMessage)).all()
            for row in rows:
                row.created_at = 1700000000.0
            db.commit()
        collected = []
        before, before_id = None, None
        for _ in range(5):
            url = f"/mobile/v1/messages?contact_id={contact_id}&limit=2"
            if before is not None:
                url += f"&before={before}&before_id={before_id}"
            page = client.get(url, headers=alice["mobile"]).json()
            collected.extend(item["body"] for item in page["items"])
            before, before_id = page["next_before"], page["next_before_id"]
            if before is None:
                break
        assert sorted(collected) == sorted(f"same-{index}" for index in range(5))
        assert len(collected) == len(set(collected))


def test_reverse_contact_request_auto_accept_returns_request_id(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "auto-a@example.com", "Milo")
        bob = verified_user(client, settings, "auto-b@example.com", "Afu")
        client.post("/mobile/v1/contacts/requests", headers=alice["mobile"],
                    json={"target_public_ref": bob["me"]["public_ref"]})
        response = client.post("/mobile/v1/contacts/requests", headers=bob["mobile"],
                               json={"target_public_ref": alice["me"]["public_ref"]})
        assert response.status_code in (200, 201), response.text
        payload = response.json()
        assert payload["status"] == "accepted" and payload["auto_accepted"] is True
        assert payload.get("request_id") and payload.get("contact_id")


def test_blocks_list_exposes_public_ref_and_unblock_round_trip(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        alice = verified_user(client, settings, "blk-a@example.com", "Milo")
        bob = verified_user(client, settings, "blk-b@example.com", "Afu")
        created = client.post("/mobile/v1/blocks", headers=alice["mobile"],
                              json={"target_public_ref": bob["me"]["public_ref"]})
        assert created.status_code == 201
        items = client.get("/mobile/v1/blocks", headers=alice["mobile"]).json()["items"]
        assert items and items[0]["user_public_ref"] == bob["me"]["public_ref"]
        assert isinstance(items[0]["created_at"], (int, float))
        removed = client.delete(f"/mobile/v1/blocks/{bob['me']['public_ref']}", headers=alice["mobile"])
        assert removed.status_code == 200
        assert client.get("/mobile/v1/blocks", headers=alice["mobile"]).json()["items"] == []
