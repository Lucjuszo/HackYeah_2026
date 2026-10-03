from dataclasses import dataclass
from io import BytesIO

from PIL import Image, ImageOps, UnidentifiedImageError

Image.MAX_IMAGE_PIXELS = 50_000_000  # guard against decompression bombs


class InvalidImage(Exception):
    pass


@dataclass
class ProcessedImage:
    data: bytes
    content_type: str
    width: int
    height: int


def process_image(raw: bytes, max_dimension: int) -> ProcessedImage:
    """Validates by actually decoding, applies EXIF rotation, downsizes and re-encodes to WebP.

    Re-encoding without passing exif drops all metadata, including GPS location from phone photos.
    """
    try:
        img = Image.open(BytesIO(raw))
        img.load()
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as e:
        raise InvalidImage from e

    img = ImageOps.exif_transpose(img)
    img.thumbnail((max_dimension, max_dimension))
    img = img.convert("RGBA" if img.has_transparency_data else "RGB")

    out = BytesIO()
    img.save(out, "WEBP", quality=85)
    return ProcessedImage(out.getvalue(), "image/webp", img.width, img.height)
