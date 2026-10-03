from io import BytesIO

import pytest
from PIL import Image

from app.images import InvalidImage, process_photo
from tests.helpers import make_image


def open_result(data: bytes) -> Image.Image:
    return Image.open(BytesIO(data))


def process(raw: bytes, full: int = 1600, thumbnail: int = 400):
    return process_photo(raw, full_dimension=full, thumbnail_dimension=thumbnail)


@pytest.mark.parametrize("fmt", ["JPEG", "PNG", "WEBP", "GIF"])
def test_converts_to_webp(fmt):
    result = process(make_image(fmt))
    for variant in (result.full, result.thumbnail):
        assert variant.content_type == "image/webp"
        assert open_result(variant.data).format == "WEBP"


def test_two_sizes_keep_aspect_ratio():
    result = process(make_image(size=(4000, 1000)))
    assert (result.full.width, result.full.height) == (1600, 400)
    assert (result.thumbnail.width, result.thumbnail.height) == (400, 100)
    assert open_result(result.full.data).size == (1600, 400)
    assert open_result(result.thumbnail.data).size == (400, 100)
    assert len(result.thumbnail.data) < len(result.full.data)


def test_portrait_limited_by_height():
    result = process(make_image(size=(1000, 3000)))
    assert (result.full.width, result.full.height) == (533, 1600)
    assert (result.thumbnail.width, result.thumbnail.height) == (133, 400)


def test_small_images_are_not_upscaled():
    result = process(make_image(size=(300, 150)))
    assert (result.full.width, result.full.height) == (300, 150)
    assert (result.thumbnail.width, result.thumbnail.height) == (300, 150)


def test_keeps_transparency():
    # Semi-transparent: a fully opaque alpha channel is legitimately dropped by the WebP encoder.
    result = process(make_image("PNG", mode="RGBA", color=(255, 0, 0, 128)))
    assert open_result(result.full.data).mode == "RGBA"
    assert open_result(result.thumbnail.data).mode == "RGBA"


def test_applies_exif_rotation_and_strips_metadata():
    exif = Image.Exif()
    exif[0x0112] = 6  # orientation: rotate 90°
    exif[0x010F] = "PhoneMaker"
    result = process(make_image(size=(300, 100), exif=exif))
    assert (result.full.width, result.full.height) == (100, 300)
    for variant in (result.full, result.thumbnail):
        assert dict(open_result(variant.data).getexif()) == {}


@pytest.mark.parametrize("raw", [b"", b"not an image", make_image()[:50]])
def test_rejects_invalid_data(raw):
    with pytest.raises(InvalidImage):
        process(raw)
