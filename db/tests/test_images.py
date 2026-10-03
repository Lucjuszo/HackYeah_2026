from io import BytesIO

import pytest
from PIL import Image

from app.images import InvalidImage, process_image
from tests.helpers import make_image


def open_result(data: bytes) -> Image.Image:
    return Image.open(BytesIO(data))


@pytest.mark.parametrize("fmt", ["JPEG", "PNG", "WEBP", "GIF"])
def test_converts_to_webp(fmt):
    result = process_image(make_image(fmt), max_dimension=2048)
    assert result.content_type == "image/webp"
    assert open_result(result.data).format == "WEBP"
    assert (result.width, result.height) == (64, 32)


def test_downscales_keeping_aspect_ratio():
    result = process_image(make_image(size=(4000, 1000)), max_dimension=2048)
    assert (result.width, result.height) == (2048, 512)
    assert open_result(result.data).size == (2048, 512)


def test_does_not_upscale():
    result = process_image(make_image(size=(100, 50)), max_dimension=2048)
    assert (result.width, result.height) == (100, 50)


def test_keeps_transparency():
    # Semi-transparent: a fully opaque alpha channel is legitimately dropped by the WebP encoder.
    result = process_image(make_image("PNG", mode="RGBA", color=(255, 0, 0, 128)), max_dimension=2048)
    assert open_result(result.data).mode == "RGBA"


def test_applies_exif_rotation_and_strips_metadata():
    exif = Image.Exif()
    exif[0x0112] = 6  # orientation: rotate 90°
    exif[0x010F] = "PhoneMaker"
    result = process_image(make_image(size=(300, 100), exif=exif), max_dimension=2048)
    assert (result.width, result.height) == (100, 300)
    assert dict(open_result(result.data).getexif()) == {}


@pytest.mark.parametrize("raw", [b"", b"not an image", make_image()[:50]])
def test_rejects_invalid_data(raw):
    with pytest.raises(InvalidImage):
        process_image(raw, max_dimension=2048)
