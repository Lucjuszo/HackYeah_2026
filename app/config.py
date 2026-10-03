import os
from typing import Any

from pydantic import SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # extra="ignore": unrelated keys in .env must not crash the app.
    # env_ignore_empty: "JWT_SECRET=" in .env means "not set", not an empty secret.
    # HACKYEAH_ENV_FILE="" disables the .env file entirely (tests must not pick up a developer's secrets).
    model_config = SettingsConfigDict(
        env_file=os.getenv("HACKYEAH_ENV_FILE", ".env") or None, extra="ignore", env_ignore_empty=True
    )

    # Remote MongoDB (e.g. Atlas) is the default. USE_REMOTE_MONGO=false switches to the
    # docker compose container below; tests always force the container.
    use_remote_mongo: bool = True
    mongodb_uri: SecretStr | None = None
    mongodb_username: str | None = None
    mongodb_password: SecretStr | None = None

    # Local container (docker compose)
    mongo_uri: str = "mongodb://root:example@localhost:27017"

    mongo_db: str = "hackyeah"

    # --- Frontend
    # Comma-separated origins allowed to call the API from a browser (CORS). "*" allows any.
    cors_origins: str = "http://localhost:5173,http://localhost:3000"
    # Public address of this API, e.g. "https://api.example.com". Photo URLs become absolute
    # (frontend on another origin can use them in <img src> as is). Unset: relative "/media/...".
    public_base_url: str | None = None
    # Places' opening hours are local time; "open now" is evaluated in this zone.
    timezone: str = "Europe/Warsaw"

    # --- Photos (app/storage.py): local disk, served under media_base_url
    media_dir: str = "media"
    media_base_url: str = "/media"
    max_photo_bytes: int = 10 * 1024 * 1024  # upload size, before processing
    max_photo_dimension: int = 1600  # longer side of the full version
    thumbnail_dimension: int = 400  # longer side of the thumbnail
    max_photos_per_place: int = 20

    # --- Rate limits per user (in memory, per process; 0 = off)
    photo_uploads_per_hour: int = 30
    comments_per_hour: int = 60

    # --- Auth (see docs/AUTH.md)
    # Signs our own access tokens. Without it a random per-process secret is used,
    # so tokens stop working after every restart – set it in .env.
    jwt_secret: SecretStr | None = None
    jwt_ttl_minutes: int = 24 * 60
    github_client_id: str | None = None
    github_client_secret: SecretStr | None = None
    google_client_id: str | None = None
    google_client_secret: SecretStr | None = None
    # Where the OAuth callback sends the browser, with "#access_token=..." appended (the frontend).
    # Unset: the callback answers with JSON, handy for testing without a frontend.
    auth_redirect_url: str | None = None
    # Comma-separated e-mails that get the admin role when they log in with a verified address.
    admin_emails: str = ""
    # POST /auth/dev-login hands out tokens for any user/role without OAuth. Never enable in production.
    auth_dev_login: bool = False

    @field_validator("jwt_secret")
    @classmethod
    def _strong_secret(cls, value: SecretStr | None) -> SecretStr | None:
        if value is not None and len(value.get_secret_value()) < 32:
            raise ValueError("JWT_SECRET must be at least 32 characters")
        return value

    def cors_origin_list(self) -> list[str]:
        return [o.strip().rstrip("/") for o in self.cors_origins.split(",") if o.strip()]

    def media_url_prefix(self) -> str:
        base = self.public_base_url.rstrip("/") if self.public_base_url else ""
        return base + "/" + self.media_base_url.strip("/")

    def admin_email_set(self) -> set[str]:
        return {e.strip().lower() for e in self.admin_emails.split(",") if e.strip()}

    def mongo_connection(self) -> tuple[str, dict[str, Any]]:
        """URI and extra MongoClient kwargs for the selected database."""
        if not self.use_remote_mongo:
            return self.mongo_uri, {}
        if self.mongodb_uri is None:
            raise RuntimeError(
                "USE_REMOTE_MONGO is enabled but MONGODB_URI is not set. "
                "Set MONGODB_URI, or USE_REMOTE_MONGO=false to use the docker compose container."
            )
        uri = self.mongodb_uri.get_secret_value()
        kwargs: dict[str, Any] = {}
        # Credentials embedded in the URI win; the separate variables only fill in a URI without them.
        if "@" not in uri.split("://", 1)[-1].split("/", 1)[0]:
            if self.mongodb_username:
                kwargs["username"] = self.mongodb_username
            if self.mongodb_password:
                kwargs["password"] = self.mongodb_password.get_secret_value()
        return uri, kwargs

    def mongo_target(self) -> str:
        """Human-readable target without credentials, for logs."""
        return f"{'remote' if self.use_remote_mongo else 'local container'} / db '{self.mongo_db}'"


settings = Settings()
