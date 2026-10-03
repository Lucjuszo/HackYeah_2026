from dataclasses import dataclass
from io import BytesIO

from PIL import Image, ImageOps, UnidentifiedImageError

Image.MAX_IMAGE_PIXELS = 50_000_000  # guard against decompression bombs

CONTENT_TYPE = "image/webp"


class InvalidImage(Exception):
    pass


@dataclass
class ProcessedImage:
    data: bytes
    content_type: str
    width: int
    height: int


@dataclass
class ProcessedPhoto:
    full: ProcessedImage
    thumbnail: ProcessedImage


def _encode(img: Image.Image, max_dimension: int, quality: int) -> ProcessedImage:
    variant = img.copy()
    variant.thumbnail((max_dimension, max_dimension))  # keeps aspect ratio, never upscales
    out = BytesIO()
    variant.save(out, "WEBP", quality=quality)
    return ProcessedImage(out.getvalue(), CONTENT_TYPE, variant.width, variant.height)


def process_photo(raw: bytes, *, full_dimension: int, thumbnail_dimension: int) -> ProcessedPhoto:
    """Validates by actually decoding, applies EXIF rotation and makes two WebP versions:
    `full` (longer side <= full_dimension) and `thumbnail` (longer side <= thumbnail_dimension).

    Re-encoding without passing exif drops all metadata, including GPS location from phone photos.
    """
    try:
        img = Image.open(BytesIO(raw))
        img.load()
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as e:
        raise InvalidImage from e

    img = ImageOps.exif_transpose(img)
    img = img.convert("RGBA" if img.has_transparency_data else "RGB")
    return ProcessedPhoto(
        full=_encode(img, full_dimension, quality=85),
        thumbnail=_encode(img, thumbnail_dimension, quality=80),
    )
