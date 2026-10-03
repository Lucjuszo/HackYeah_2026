"""Keeps the example payloads shared with the team valid as the models evolve."""

import json

import pytest

from app.models.comment import CommentCreate
from app.models.place import PlaceCreate, PlaceUpdate
from app.models.rating import RatingCreate
from tests.helpers import EXAMPLES_DIR

PLACE_FILES = sorted((EXAMPLES_DIR / "places").glob("*.json"))


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def test_there_are_examples():
    assert len(PLACE_FILES) >= 5


@pytest.mark.parametrize("path", PLACE_FILES, ids=lambda p: p.name)
def test_place_example_is_valid(path):
    PlaceCreate.model_validate(load(path))


@pytest.mark.parametrize(
    ("filename", "model"),
    [("place-update.json", PlaceUpdate), ("rating.json", RatingCreate), ("comment.json", CommentCreate)],
)
def test_request_example_is_valid(filename, model):
    model.model_validate(load(EXAMPLES_DIR / "requests" / filename))


@pytest.mark.parametrize("path", PLACE_FILES, ids=lambda p: p.name)
def test_place_example_can_be_created(client, path):
    assert client.post("/places", json=load(path)).status_code == 201
