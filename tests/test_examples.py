"""Keeps the example payloads shared with the team valid as the models evolve."""

import json

import pytest

from app.models.comment import CommentCreate, CommentUpdate
from app.models.place import PlaceCreate, PlaceUpdate
from app.models.rating import RatingCreate
from app.models.user import DevLoginRequest
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
    [
        ("place-update.json", PlaceUpdate),
        ("rating.json", RatingCreate),
        ("comment.json", CommentCreate),
        ("comment-update.json", CommentUpdate),
        ("dev-login-user.json", DevLoginRequest),
        ("dev-login-admin.json", DevLoginRequest),
    ],
)
def test_request_example_is_valid(filename, model):
    model.model_validate(load(EXAMPLES_DIR / "requests" / filename))


@pytest.mark.parametrize("path", PLACE_FILES, ids=lambda p: p.name)
def test_place_example_can_be_created(client, path):
    assert client.post("/places", json=load(path)).status_code == 201


def test_every_request_example_is_covered():
    covered = {"place-update.json", "rating.json", "comment.json", "comment-update.json",
               "dev-login-user.json", "dev-login-admin.json"}
    assert {p.name for p in (EXAMPLES_DIR / "requests").glob("*.json")} == covered


def test_postman_collection_is_valid_json():
    collection = load(EXAMPLES_DIR.parent / "postman" / "HackYeah.postman_collection.json")
    assert collection["info"]["schema"].endswith("v2.1.0/collection.json")
    assert {v["key"] for v in collection["variable"]} >= {"baseUrl", "token", "adminToken", "placeId"}
