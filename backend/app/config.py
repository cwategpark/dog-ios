from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="WAGELPAW_", env_file=".env", extra="ignore")

    environment: Literal["development", "test", "production"] = "development"
    database_url: SecretStr = SecretStr("sqlite:///./var/wagelpaw.db")
    dev_token: SecretStr = SecretStr("")
    storage_path: Path = Path("var/media")
    allowed_shops: list[str] = Field(default_factory=list)
    allowed_origins: list[str] = Field(default_factory=list)
    shopify_api_secret: SecretStr = SecretStr("")
    shopify_store_domain: str = ""
    shopify_access_token: SecretStr = SecretStr("")
    shopify_api_version: str = "2026-07"
    image_provider: Literal["ark", "gemini"] = "ark"
    ark_api_key: SecretStr = SecretStr("")
    ark_model: str = "doubao-seedream-5-0-flash-260915"
    gemini_api_key: SecretStr = SecretStr("")
    gemini_model: str = ""
    gemini_endpoint: str = "https://generativelanguage.googleapis.com/v1beta/interactions"
    triposr_base_url: str = ""
    cat_fitting_product_handle: str = "daily-harness"
    cat_fitting_pet_url: str = ""
    cat_fitting_garment_url: str = ""
    provider_timeout_seconds: int = 480
    proxy_timestamp_tolerance_seconds: int = 300
    session_ttl_seconds: int = 86400
    session_job_limit: int = 24
    jobs_per_session_hour: int = 3
    jobs_per_ip_hour: int = 3
    sessions_per_ip_hour: int = 10
    trusted_proxy_ips: list[str] = Field(default_factory=lambda: ["127.0.0.1", "::1"])
    trusted_proxy_hops: int = 1
    max_upload_bytes: int = 8 * 1024 * 1024
    max_upload_pixels: int = 24_000_000
    max_pending_jobs: int = 100
    lease_seconds: int = 900
    heartbeat_seconds: int = 15
    worker_poll_seconds: float = 2.0
    media_retention_seconds: int = 86400
    catalog_reconcile_seconds: int = 86400
    rate_limit_salt: SecretStr = SecretStr("")
    # --- dog-ios shared backend additions ---
    public_base_url: str = ""
    public_assets_dir: Path = Path(__file__).resolve().parents[2] / "public-assets"
    # The email claim-link bridge is closed by default: while disabled the link endpoints
    # answer 503 claim_link_disabled and no redeemable token/URL is ever produced or returned.
    claim_link_enabled: bool = False
    claim_link_secret: SecretStr = SecretStr("")
    claim_link_ttl_seconds: int = 1200
    otp_ttl_seconds: int = 600
    otp_max_attempts: int = 5
    otp_resend_cooldown_seconds: int = 60
    otp_per_email_hour: int = 5
    otp_per_ip_hour: int = 10
    access_token_ttl_seconds: int = 900
    refresh_token_ttl_seconds: int = 2592000
    expose_dev_otp: bool = False
    dev_email_outbox: bool = False
    email_outbox_path: Path = Path("var/email-outbox.jsonl")
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_username: str = ""
    smtp_password: SecretStr = SecretStr("")
    smtp_from: str = ""
    smtp_use_tls: bool = True
    archived_upload_retention_seconds: int = 315360000
    discovery_location_ttl_seconds: int = 86400
    discovery_max_radius_km: int = 25
    discovery_default_radius_km: int = 5

    @model_validator(mode="after")
    def production_guards(self):
        if self.session_ttl_seconds <= 0 or self.session_job_limit <= 0:
            raise ValueError("Session expiry and quota must be positive")
        if not 1 <= self.trusted_proxy_hops <= 5:
            raise ValueError("Configure between one and five trusted proxy hops")
        if self.lease_seconds <= self.heartbeat_seconds * 2:
            raise ValueError("Lease must exceed two heartbeat intervals")
        if "*" in self.allowed_origins:
            raise ValueError("Wildcard CORS is forbidden")
        if self.environment == "production":
            if self.database_url.get_secret_value().startswith("sqlite"):
                raise ValueError("Production requires PostgreSQL")
            if self.dev_token.get_secret_value():
                raise ValueError("Development authentication is forbidden in production")
            if not self.shopify_api_secret.get_secret_value() or not self.allowed_shops:
                raise ValueError("Production requires Shopify signatures and an explicit shop allowlist")
            if not self.shopify_store_domain or self.allowed_shops != [self.shopify_store_domain]:
                raise ValueError("One installation must bind exactly one Shopify store")
            if not self.rate_limit_salt.get_secret_value():
                raise ValueError("Production requires a rate-limit HMAC salt")
            if self.expose_dev_otp:
                raise ValueError("Exposing development OTP codes is forbidden in production")
            if self.dev_email_outbox:
                raise ValueError("The local email outbox is forbidden in production")
        return self

    @property
    def local_shop(self):
        return self.shopify_store_domain or "development.local"

    @property
    def email_delivery_mode(self):
        if self.smtp_host and self.smtp_from:
            return "email"
        if self.dev_email_outbox:
            return "outbox"
        return "unavailable"

    @property
    def claim_link_hmac_secret(self):
        return (self.claim_link_secret.get_secret_value() or self.rate_limit_salt.get_secret_value()
                or self.dev_token.get_secret_value())


@lru_cache
def get_settings():
    return Settings()
