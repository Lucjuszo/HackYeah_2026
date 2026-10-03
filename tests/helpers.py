from io import BytesIO
from pathlib import Path

from PIL import Image

from app.auth.tokens import create_access_token
from app.config import settings
from app.models.user import Role

MEDIA_DIR = Path(settings.media_dir)
EXAMPLES_DIR = Path(__file__).parent.parent / "examples"

DEFAULT_USER = "tester"
# An empty Authorization header overrides the client's default one: the request is anonymous.
ANONYMOUS = {"Authorization": ""}


def make_image(
    fmt: str = "JPEG", size: tuple[int, int] = (64, 32), mode: str = "RGB", color="red", **save_kwargs
) -> bytes:
    buf = BytesIO()
    Image.new(mode, size, color).save(buf, fmt, **save_kwargs)
    return buf.getvalue()


def as_user(user_id: str, role: Role = Role.USER, name: str | None = None) -> dict[str, str]:
    """Authorization header with a valid access token for the given user id."""
    token, _ = create_access_token(user_id, name or user_id, role)
    return {"Authorization": f"Bearer {token}"}


def as_admin(user_id: str = "admin") -> dict[str, str]:
    return as_user(user_id, Role.ADMIN)
