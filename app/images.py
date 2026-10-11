import warnings
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


def _open(raw: bytes, full_dimension: int) -> Image.Image:
    """Decodes the image, refusing ones that would need too much memory (the Pi's API container has 512 MB).

    JPEG (nearly every phone photo) is decoded straight at a reduced scale (1/2, 1/4, 1/8) that still
    covers `full_dimension`, so a 64 MP photo costs a fraction of its full size; such photos are accepted
    up to Pillow's hard limit (2 x MAX_IMAGE_PIXELS). Other formats are decoded at full size and must
    stay under MAX_IMAGE_PIXELS – Pillow alone would only warn between the two limits.
    """
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", Image.DecompressionBombWarning)  # checked below instead
        img = Image.open(BytesIO(raw))
    if img.format != "JPEG" and img.width * img.height > Image.MAX_IMAGE_PIXELS:
        raise InvalidImage(f"image too large: {img.width}x{img.height}")
    img.draft("RGB", (full_dimension, full_dimension))
    img.load()
    return img


def process_photo(raw: bytes, *, full_dimension: int, thumbnail_dimension: int) -> ProcessedPhoto:
    """Validates by actually decoding, applies EXIF rotation and makes two WebP versions:
    `full` (longer side <= full_dimension) and `thumbnail` (longer side <= thumbnail_dimension).

    Re-encoding without passing exif drops all metadata, including GPS location from phone photos.
    """
    # Corrupt files surface as any of these, also from the EXIF data; never as a 500.
    try:
        img = _open(raw, full_dimension)
        img = ImageOps.exif_transpose(img)
        img = img.convert("RGBA" if img.has_transparency_data else "RGB")
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError, EOFError, Image.DecompressionBombError) as e:
        raise InvalidImage from e
    return ProcessedPhoto(
        full=_encode(img, full_dimension, quality=85),
        thumbnail=_encode(img, thumbnail_dimension, quality=80),
    )
