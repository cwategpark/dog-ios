"""Deterministic regression for the block/create/accept/send check-then-act race.

The audited reproduction paused after ``blocked_between`` returned false, committed a block in
another thread, then resumed the write; the blocked row reappeared after unblock. Every mutation
now takes the same persistent ordered pair lock before checking the block fact, so the competing
block waits for the whole check+write transaction.
"""
import threading
import time

import pytest
from sqlalchemy import select, update
from sqlalchemy.dialects import postgresql, sqlite
from sqlalchemy.schema import CreateTable
from fastapi import HTTPException

from app import social
from app.models import Contact, ContactMessage, ContactRequest, SocialPairLock, User, UserBlock

from .support import build_settings, claim_website_session, issue_guest, make_client, mobile_login


def _users_and_tokens(client, settings):
    headers_a, _ = issue_guest(client, email="lock-a@example.com",
                               profile={"type": "dog", "age_months": 12, "dog_size": "small", "name": "Lock A"})
    claim_website_session(client, settings, headers_a, "lock-a@example.com")
    _ta, mobile_a = mobile_login(client, settings, "lock-a@example.com")
    headers_b, _ = issue_guest(client, email="lock-b@example.com",
                               profile={"type": "cat", "age_months": 8, "name": "Lock B"})
    claim_website_session(client, settings, headers_b, "lock-b@example.com")
    _tb, mobile_b = mobile_login(client, settings, "lock-b@example.com")
    sessions = client.app.state.sessions
    with sessions() as db:
        user_a = db.scalar(select(User).where(User.email_normalized == "lock-a@example.com"))
        user_b = db.scalar(select(User).where(User.email_normalized == "lock-b@example.com"))
    return user_a, user_b, mobile_a, mobile_b


def _pair_key(a, b):
    return f"{min(a, b)}:{max(a, b)}"


def _start_thread(target, results, name):
    def run():
        try:
            results[name] = target()
        except Exception as error:  # noqa: BLE001 - assertions inspect failures
            results[name] = error

    thread = threading.Thread(target=run, name=name, daemon=True)
    thread.start()
    return thread


def _gated_hook(entered, release):
    def hook(stage, *_args, **_kwargs):
        if stage == "pair_locked":
            entered.set()
            assert release.wait(15), "test did not release pair lock in time"
    return hook


def _accepted_pair(client, settings):
    user_a, user_b, mobile_a, mobile_b = _users_and_tokens(client, settings)
    sessions = client.app.state.sessions
    social.create_contact_request(sessions, user_a.id, user_b.public_ref, None)
    request = social.list_contact_requests(sessions, user_b.id)["items"][0]
    social.respond_to_request(sessions, user_b.id, request["request_id"], True)
    contact = social.list_contacts(sessions, user_a.id)["items"][0]
    return user_a, user_b, contact["contact_id"]


def test_create_cannot_commit_after_a_concurrent_block_check(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, _ma, _mb = _users_and_tokens(client, settings)
        sessions = client.app.state.sessions
        entered, release = threading.Event(), threading.Event()
        op_result = {}
        thread = _start_thread(
            lambda: social.create_contact_request(sessions, user_a.id, user_b.public_ref, None,
                                                  hook=_gated_hook(entered, release)),
            op_result, "create")
        assert entered.wait(15), "create never took the pair lock"
        block_result = {}
        block_started = threading.Event()

        def block():
            block_started.set()
            return social.add_block(sessions, user_b.id, user_a.public_ref)

        block_thread = _start_thread(block, block_result, "block")
        assert block_started.wait(5)
        time.sleep(0.3)
        assert not isinstance(block_result.get("block"), dict)
        with sessions() as db:
            assert db.scalar(select(UserBlock).where(UserBlock.blocker_id == user_b.id)) is None
        release.set()
        thread.join(15)
        block_thread.join(15)
        assert not thread.is_alive() and not block_thread.is_alive()
        assert isinstance(op_result.get("create"), tuple), op_result
        assert isinstance(block_result.get("block"), dict), block_result
        with sessions() as db:
            row = db.scalar(select(ContactRequest).where(ContactRequest.from_user_id == user_a.id))
            assert row is not None and row.status == "cancelled"
        social.remove_block(sessions, user_b.id, user_a.public_ref)
        requests = social.list_contact_requests(sessions, user_b.id)["items"]
        assert all(item["status"] != "pending" for item in requests)


def test_send_cannot_commit_after_a_concurrent_block_check(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, contact_id = _accepted_pair(client, settings)
        sessions = client.app.state.sessions
        contact_id = social.list_contacts(sessions, user_a.id)["items"][0]["contact_id"]
        entered, release = threading.Event(), threading.Event()
        op_result = {}
        thread = _start_thread(
            lambda: social.send_message(sessions, user_a.id, contact_id, "sent under pair lock",
                                        "lock-msg-1", hook=_gated_hook(entered, release)),
            op_result, "send")
        assert entered.wait(15), "send never took the pair lock"
        block_result = {}
        block_started = threading.Event()

        def block():
            block_started.set()
            return social.add_block(sessions, user_b.id, user_a.public_ref)

        block_thread = _start_thread(block, block_result, "block")
        assert block_started.wait(5)
        time.sleep(0.3)
        assert not isinstance(block_result.get("block"), dict)
        with sessions() as db:
            assert db.scalar(select(UserBlock).where(UserBlock.blocker_id == user_b.id)) is None
        release.set()
        thread.join(15)
        block_thread.join(15)
        assert not thread.is_alive() and not block_thread.is_alive()
        assert isinstance(op_result.get("send"), tuple), op_result
        assert isinstance(block_result.get("block"), dict), block_result
        with pytest.raises(HTTPException) as blocked_read:
            social.list_messages(sessions, user_a.id, contact_id)
        assert blocked_read.value.status_code == 403
        social.remove_block(sessions, user_b.id, user_a.public_ref)
        bodies = [item["body"] for item in social.list_messages(sessions, user_a.id, contact_id)["items"]]
        assert "sent under pair lock" in bodies
        # Block-first is a hard rejection, not a delayed write.
        social.add_block(sessions, user_b.id, user_a.public_ref)
        with pytest.raises(HTTPException) as rejected:
            social.send_message(sessions, user_a.id, contact_id, "after block", "lock-msg-3")
        assert rejected.value.status_code == 403
        social.remove_block(sessions, user_b.id, user_a.public_ref)


def test_accept_cannot_commit_after_a_concurrent_block_check(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, _ma, _mb = _users_and_tokens(client, settings)
        sessions = client.app.state.sessions
        social.create_contact_request(sessions, user_a.id, user_b.public_ref, None)
        request = social.list_contact_requests(sessions, user_b.id)["items"][0]
        entered, release = threading.Event(), threading.Event()
        op_result = {}
        thread = _start_thread(
            lambda: social.respond_to_request(sessions, user_b.id, request["request_id"], True,
                                              hook=_gated_hook(entered, release)),
            op_result, "accept")
        assert entered.wait(15), "accept never took the pair lock"
        block_result = {}
        block_started = threading.Event()

        def block():
            block_started.set()
            return social.add_block(sessions, user_a.id, user_b.public_ref)

        block_thread = _start_thread(block, block_result, "block")
        assert block_started.wait(5)
        time.sleep(0.3)
        assert not isinstance(block_result.get("block"), dict)
        with sessions() as db:
            assert db.scalar(select(UserBlock).where(UserBlock.blocker_id == user_a.id)) is None
        release.set()
        thread.join(15)
        block_thread.join(15)
        assert not thread.is_alive() and not block_thread.is_alive()
        assert isinstance(op_result.get("accept"), dict), op_result
        assert isinstance(block_result.get("block"), dict), block_result
        with sessions() as db:
            assert db.get(ContactRequest, request["request_id"]).status == "accepted"
            assert db.scalar(select(Contact)) is not None
        social.remove_block(sessions, user_a.id, user_b.public_ref)
        assert len(social.list_contacts(sessions, user_a.id)["items"]) == 1


def test_block_first_rejects_create_and_send(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, contact_id = _accepted_pair(client, settings)
        sessions = client.app.state.sessions
        social.add_block(sessions, user_b.id, user_a.public_ref)
        with pytest.raises(HTTPException) as create_error:
            social.create_contact_request(sessions, user_a.id, user_b.public_ref, None)
        assert create_error.value.status_code == 403
        with pytest.raises(HTTPException) as send_error:
            social.send_message(sessions, user_a.id, contact_id, "blocked", "block-first-1")
        assert send_error.value.status_code == 403
        social.remove_block(sessions, user_b.id, user_a.public_ref)


def test_block_first_rejects_accept(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, _ma, _mb = _users_and_tokens(client, settings)
        sessions = client.app.state.sessions
        social.create_contact_request(sessions, user_a.id, user_b.public_ref, None)
        pending = social.list_contact_requests(sessions, user_b.id)["items"][0]
        social.add_block(sessions, user_a.id, user_b.public_ref)
        with pytest.raises(HTTPException) as accept_error:
            social.respond_to_request(sessions, user_b.id, pending["request_id"], True)
        assert accept_error.value.status_code in (403, 409)
        social.remove_block(sessions, user_a.id, user_b.public_ref)


def test_pair_lock_row_is_ordered_persistent_and_portable_sql(tmp_path):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, _ma, _mb = _users_and_tokens(client, settings)
        sessions = client.app.state.sessions
        social.add_block(sessions, user_b.id, user_a.public_ref)
        with sessions() as db:
            row = db.get(SocialPairLock, _pair_key(user_a.id, user_b.id))
            assert row is not None
            assert row.pair_key == _pair_key(user_a.id, user_b.id)
        social.remove_block(sessions, user_b.id, user_a.public_ref)
        with sessions() as db:
            assert db.get(SocialPairLock, _pair_key(user_a.id, user_b.id)) is not None

    statement = update(SocialPairLock).where(SocialPairLock.pair_key == "a:b").values(
        created_at=SocialPairLock.created_at)
    assert "UPDATE social_pair_locks" in str(statement.compile(dialect=postgresql.dialect()))
    assert "UPDATE social_pair_locks" in str(statement.compile(dialect=sqlite.dialect()))
    for dialect in (postgresql.dialect(), sqlite.dialect()):
        ddl = str(CreateTable(SocialPairLock.__table__).compile(dialect=dialect))
        assert "social_pair_locks" in ddl and "pair_key" in ddl


def _gated_blocked_check(monkeypatch, entered, release):
    original = social.blocked_between

    def gate(db, first, second):
        value = original(db, first, second)
        if threading.current_thread().name == "audited-operation" and not value:
            entered.set()
            assert release.wait(15), "test did not release blocked_between gate"
        return value

    monkeypatch.setattr(social, "blocked_between", gate)


def test_audit_gate_create_cannot_pass_after_block_commit(tmp_path, monkeypatch):
    """Mirror the reviewer's gate at blocked_between, not only the pair-lock hook."""
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, _ma, _mb = _users_and_tokens(client, settings)
        sessions = client.app.state.sessions
        entered, release = threading.Event(), threading.Event()
        _gated_blocked_check(monkeypatch, entered, release)
        op_result = {}
        op_thread = _start_thread(
            lambda: social.create_contact_request(sessions, user_a.id, user_b.public_ref, None),
            op_result, "audited-operation")
        assert entered.wait(15), "operation never reached the gated block check"
        block_done = threading.Event()
        block_result = {}

        def block():
            block_result["block"] = social.add_block(sessions, user_b.id, user_a.public_ref)
            block_done.set()

        block_thread = _start_thread(block, {}, "audited-block")
        time.sleep(0.3)
        assert not block_done.is_set(), "block committed while the operation held the pair lock"
        with sessions() as db:
            assert db.scalar(select(UserBlock)) is None
        release.set()
        op_thread.join(15)
        block_thread.join(15)
        assert not op_thread.is_alive() and not block_thread.is_alive()
        assert isinstance(op_result.get("audited-operation"), tuple), op_result
        assert isinstance(block_result.get("block"), dict), block_result
        with sessions() as db:
            request = db.scalar(select(ContactRequest).where(ContactRequest.from_user_id == user_a.id))
            assert request is not None and request.status == "cancelled"
        social.remove_block(sessions, user_b.id, user_a.public_ref)
        assert all(item["status"] != "pending"
                   for item in social.list_contact_requests(sessions, user_b.id)["items"])


def test_audit_gate_send_cannot_pass_after_block_commit(tmp_path, monkeypatch):
    settings = build_settings(tmp_path)
    with make_client(settings) as client:
        user_a, user_b, contact_id = _accepted_pair(client, settings)
        sessions = client.app.state.sessions
        entered, release = threading.Event(), threading.Event()
        _gated_blocked_check(monkeypatch, entered, release)
        op_result = {}
        op_thread = _start_thread(
            lambda: social.send_message(sessions, user_a.id, contact_id,
                                        "after gated check", "audit-gated-1"),
            op_result, "audited-operation")
        assert entered.wait(15), "send never reached the gated block check"
        block_done = threading.Event()
        block_result = {}

        def block():
            block_result["block"] = social.add_block(sessions, user_b.id, user_a.public_ref)
            block_done.set()

        block_thread = _start_thread(block, {}, "audited-block")
        time.sleep(0.3)
        assert not block_done.is_set(), "block committed between send's check and write"
        with sessions() as db:
            assert db.scalar(select(UserBlock)) is None
        release.set()
        op_thread.join(15)
        block_thread.join(15)
        assert not op_thread.is_alive() and not block_thread.is_alive()
        assert isinstance(op_result.get("audited-operation"), tuple), op_result
        assert isinstance(block_result.get("block"), dict), block_result
        with pytest.raises(HTTPException) as blocked_read:
            social.list_messages(sessions, user_a.id, contact_id)
        assert blocked_read.value.status_code == 403
        social.remove_block(sessions, user_b.id, user_a.public_ref)
        # Sent before the block took effect, so it is visible after unblock, never "sent after".
        assert any(item["body"] == "after gated check"
                   for item in social.list_messages(sessions, user_a.id, contact_id)["items"])
