#!/usr/bin/env python3
"""Copy var/logs/*.log to var/logs-public/ with emails, tokens, OTP codes redacted.

The delivery package ships only these sanitized logs; raw logs remain local for debugging.
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "var" / "logs"
DST = ROOT / "var" / "logs-public"

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# Long opaque bearer/token/secret values (base64url, JWT-ish, hex session ids).
LONG_TOKEN = re.compile(r"\b[A-Za-z0-9_\-]{40,}\b")
BEARER = re.compile(r"(?i)(authorization\s*[:=]\s*bearer\s+)\S+")
DEV_CODE = re.compile(r'(?i)("?dev_code"?\s*[:=]\s*"?)(\d{6})')


def sanitize(text: str) -> str:
    text = BEARER.sub(r"\1<redacted-token>", text)
    text = DEV_CODE.sub(r"\1<redacted-otp>", text)
    text = EMAIL.sub("<redacted-email>", text)
    # Keep 64-hex sha256 evidence (public model hash) but redact other long opaque credentials.
    def token_repl(match: re.Match[str]) -> str:
        value = match.group(0)
        if re.fullmatch(r"[0-9a-fA-F]{64}", value):
            return value
        return "<redacted-token>"

    return LONG_TOKEN.sub(token_repl, text)


def main() -> int:
    DST.mkdir(parents=True, exist_ok=True)
    count = 0
    for path in sorted(SRC.glob("*.log")):
        output = DST / path.name
        output.write_text(sanitize(path.read_text(errors="replace")), encoding="utf-8")
        count += 1
    print(f"sanitized {count} log(s) -> {DST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
