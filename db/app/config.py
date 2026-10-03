from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env")

    mongo_uri: str = "mongodb://root:example@localhost:27017"
    mongo_db: str = "hackyeah"

    # Local disk for dev / single-VPS prod; swap for an S3-compatible backend later (see app/storage.py).
    media_dir: str = "media"
    media_base_url: str = "/media"
    max_photo_bytes: int = 10 * 1024 * 1024
    max_photo_dimension: int = 2048
    max_photos_per_place: int = 20


settings = Settings()
