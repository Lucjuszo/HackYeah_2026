from typing import Any

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # extra="ignore": unrelated keys in .env must not crash the app.
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Remote MongoDB (e.g. Atlas) is the default. USE_REMOTE_MONGO=false switches to the
    # docker compose container below; tests always force the container.
    use_remote_mongo: bool = True
    mongodb_uri: SecretStr | None = None
    mongodb_username: str | None = None
    mongodb_password: SecretStr | None = None

    # Local container (docker compose)
    mongo_uri: str = "mongodb://root:example@localhost:27017"

    mongo_db: str = "hackyeah"

    # Local disk for dev / single-VPS prod; swap for an S3-compatible backend later (see app/storage.py).
    media_dir: str = "media"
    media_base_url: str = "/media"
    max_photo_bytes: int = 10 * 1024 * 1024
    max_photo_dimension: int = 2048
    max_photos_per_place: int = 20

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
