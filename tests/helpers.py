from io import BytesIO
from pathlib import Path

from PIL import Image

from app.config import settings

MEDIA_DIR = Path(settings.media_dir)
EXAMPLES_DIR = Path(__file__).parent.parent / "examples"


def make_image(
    fmt: str = "JPEG", size: tuple[int, int] = (64, 32), mode: str = "RGB", color="red", **save_kwargs
) -> bytes:
    buf = BytesIO()
    Image.new(mode, size, color).save(buf, fmt, **save_kwargs)
    return buf.getvalue()


def as_user(user_id: str) -> dict[str, str]:
    return {"X-User-Id": user_id}
