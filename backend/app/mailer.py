"""Email normalization and deliberately boring delivery adapters.

Production uses SMTP configured entirely through environment variables. Local test and
development runs may enable a JSONL outbox; OTP codes are never logged and never
returned in production responses.
"""
import json
import re
import smtplib
import ssl
import time
from email.message import EmailMessage
from pathlib import Path

from fastapi import HTTPException

EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def normalize_email(raw) -> str:
    value = str(raw or "").strip()
    if not value or len(value) > 254 or value.count("@") != 1:
        raise ValueError("invalid_email")
    local, domain = value.split("@", 1)
    if not local or not domain or len(local) > 64 or " " in value:
        raise ValueError("invalid_email")
    normalized = f"{local}@{domain}".lower()
    if not EMAIL_PATTERN.fullmatch(normalized):
        raise ValueError("invalid_email")
    # Deliberately do not strip dots or plus tags: only case/whitespace normalization.
    return normalized


def display_email(raw) -> str:
    return str(raw or "").strip()


def mask_email(normalized: str) -> str:
    local, _, domain = normalized.partition("@")
    if len(local) <= 2:
        masked_local = local[0] + "*" if local else "*"
    else:
        masked_local = local[0] + "*" * (len(local) - 2) + local[-1]
    return f"{masked_local}@{domain}"


def delivery_mode(settings) -> str:
    if settings.smtp_host and settings.smtp_from:
        return "email"
    if settings.dev_email_outbox:
        return "outbox"
    return "unavailable"


def delivery_available(settings) -> bool:
    return delivery_mode(settings) != "unavailable"


def _write_outbox(settings, payload: dict) -> None:
    path = Path(settings.email_outbox_path)
    if path.parent and str(path.parent) not in ("", "."):
        path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps({"created_at": time.time(), **payload}, ensure_ascii=False, sort_keys=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def _send_smtp(settings, to_address: str, subject: str, body: str) -> None:
    message = EmailMessage()
    message["From"] = settings.smtp_from
    message["To"] = to_address
    message["Subject"] = subject
    message.set_content(body)
    try:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as client:
            if settings.smtp_use_tls:
                client.starttls(context=ssl.create_default_context())
            if settings.smtp_username:
                client.login(settings.smtp_username, settings.smtp_password.get_secret_value())
            client.send_message(message)
    except (OSError, smtplib.SMTPException) as error:
        raise HTTPException(503, "email_delivery_unavailable") from error


def deliver_otp(settings, email_normalized: str, code: str, purpose: str) -> str:
    mode = delivery_mode(settings)
    if mode == "unavailable":
        raise HTTPException(503, "email_delivery_unavailable")
    subject = "你的 dog-ios 验证码" if purpose != "website_claim" else "认领你的宠物资料到 App"
    body = f"验证码：{code}\n\n10 分钟内有效，请勿转发。若不是你本人操作，请忽略本邮件。"
    if mode == "outbox":
        _write_outbox(settings, {"kind": "otp", "to": email_normalized, "purpose": purpose, "code": code})
    else:
        _send_smtp(settings, email_normalized, subject, body)
    return mode


def deliver_claim_link(settings, email_normalized: str, url: str, expires_at: float) -> str:
    mode = delivery_mode(settings)
    if mode == "unavailable":
        raise HTTPException(503, "claim_link_delivery_unavailable")
    body = f"打开以下链接认领你在网站上的宠物资料与图片（一次性，{int(expires_at - time.time()) // 60} 分钟内有效）：\n{url}\n"
    if mode == "outbox":
        _write_outbox(settings, {"kind": "claim_link", "to": email_normalized, "url": url, "expires_at": expires_at})
    else:
        _send_smtp(settings, email_normalized, "把你的宠物资料保存到 dog-ios App", body)
    return mode
