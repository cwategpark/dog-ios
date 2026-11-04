"""Generate docs/openapi.json from the real FastAPI application (no server needed)."""
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BACKEND = REPO / "backend"
sys.path.insert(0, str(BACKEND))

from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402


def main():
    settings = Settings(
        environment="test",
        database_url="sqlite:///./var/openapi-export.db",
        dev_token="openapi-export-token",
        rate_limit_salt="openapi-export-salt",
        shopify_api_secret="openapi-export-secret",
        allowed_shops=["example.myshopify.com"],
        public_assets_dir=REPO / "public-assets",
    )
    schema = create_app(settings).openapi()
    output = REPO / "docs" / "openapi.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(schema, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    print(f" wrote {output} ({output.stat().st_size} bytes, {len(schema['paths'])} paths)")


if __name__ == "__main__":
    main()
