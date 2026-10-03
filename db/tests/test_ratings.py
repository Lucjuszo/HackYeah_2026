import random
from statistics import mean

import pytest
from bson import ObjectId

from app.auth import MOCK_USER_ID
from tests.helpers import as_user


def rate(client, place_id, score, user="anna"):
    return client.put(f"/places/{place_id}/ratings/me", json={"score": score}, headers=as_user(user))


def unrate(client, place_id, user="anna"):
    return client.delete(f"/places/{place_id}/ratings/me", headers=as_user(user))


def summary(client, place_id):
    return client.get(f"/places/{place_id}/ratings").json()


def test_new_place_has_no_rating(client, created_place):
    assert created_place["rating"] == {"average": None, "count": 0}
    assert summary(client, created_place["id"]) == {"average": None, "count": 0}


def test_first_rating(client, created_place):
    response = rate(client, created_place["id"], 4)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["rating"]["score"] == 4
    assert body["rating"]["user_id"] == "anna"
    assert body["rating"]["place_id"] == created_place["id"]
    assert body["summary"] == {"average": 4, "count": 1}


def test_average_of_several_users(client, created_place):
    rate(client, created_place["id"], 5, user="anna")
    rate(client, created_place["id"], 4, user="bartek")
    result = rate(client, created_place["id"], 3, user="celina").json()
    assert result["summary"] == {"average": pytest.approx(4), "count": 3}
    assert client.get(f"/places/{created_place['id']}").json()["rating"] == result["summary"]


def test_changing_rating_replaces_it(client, created_place):
    rate(client, created_place["id"], 5, user="anna")
    rate(client, created_place["id"], 1, user="bartek")
    result = rate(client, created_place["id"], 2, user="bartek").json()
    assert result["summary"]["count"] == 2
    assert result["summary"]["average"] == pytest.approx(3.5)


def test_same_score_again_is_noop(client, created_place):
    first = rate(client, created_place["id"], 4).json()
    second = rate(client, created_place["id"], 4).json()
    assert second["summary"] == {"average": 4, "count": 1}
    assert second["rating"]["created_at"] == first["rating"]["created_at"]


def test_rating_keeps_created_at_on_change(client, created_place):
    first = rate(client, created_place["id"], 4).json()["rating"]
    second = rate(client, created_place["id"], 2).json()["rating"]
    assert second["created_at"] == first["created_at"]
    assert second["updated_at"] >= first["updated_at"]


def test_delete_rating(client, created_place):
    rate(client, created_place["id"], 5, user="anna")
    rate(client, created_place["id"], 2, user="bartek")
    response = unrate(client, created_place["id"], user="anna")
    assert response.status_code == 200
    assert response.json() == {"average": 2, "count": 1}


def test_delete_last_rating_resets_summary(client, created_place):
    rate(client, created_place["id"], 5)
    assert unrate(client, created_place["id"]).json() == {"average": None, "count": 0}


def test_delete_without_rating(client, created_place):
    assert unrate(client, created_place["id"]).status_code == 404


def test_get_my_rating(client, created_place):
    assert client.get(f"/places/{created_place['id']}/ratings/me", headers=as_user("anna")).status_code == 404
    rate(client, created_place["id"], 3, user="anna")
    mine = client.get(f"/places/{created_place['id']}/ratings/me", headers=as_user("anna")).json()
    assert mine["score"] == 3
    assert client.get(f"/places/{created_place['id']}/ratings/me", headers=as_user("bartek")).status_code == 404


def test_default_mock_user(client, created_place):
    result = client.put(f"/places/{created_place['id']}/ratings/me", json={"score": 4}).json()
    assert result["rating"]["user_id"] == MOCK_USER_ID


@pytest.mark.parametrize("score", [0, 6, 3.5, "five", None])
def test_invalid_score(client, created_place, score):
    response = client.put(f"/places/{created_place['id']}/ratings/me", json={"score": score})
    assert response.status_code == 422


@pytest.mark.parametrize("place_id", [str(ObjectId()), "not-an-id"])
def test_unknown_place(client, place_id):
    assert rate(client, place_id, 5).status_code == 404
    assert unrate(client, place_id).status_code == 404
    assert client.get(f"/places/{place_id}/ratings").status_code == 404


def test_one_rating_document_per_user(client, created_place, db):
    for score in (1, 2, 3):
        rate(client, created_place["id"], score)
    assert db.ratings.count_documents({"place_id": ObjectId(created_place["id"])}) == 1


def test_ratings_are_per_place(client, created_place, minimal_payload):
    other = client.post("/places", json=minimal_payload).json()
    rate(client, created_place["id"], 5)
    rate(client, other["id"], 1)
    assert summary(client, created_place["id"]) == {"average": 5, "count": 1}
    assert summary(client, other["id"]) == {"average": 1, "count": 1}


def test_incremental_average_matches_full_recalculation(client, created_place):
    """Random add / change / remove sequence: the incrementally kept average must equal a plain mean."""
    rng = random.Random(2026)
    users = [f"user{i}" for i in range(15)]
    expected: dict[str, int] = {}

    for _ in range(200):
        user = rng.choice(users)
        if user in expected and rng.random() < 0.25:
            unrate(client, created_place["id"], user=user)
            del expected[user]
        else:
            score = rng.randint(1, 5)
            rate(client, created_place["id"], score, user=user)
            expected[user] = score

        result = summary(client, created_place["id"])
        assert result["count"] == len(expected)
        if expected:
            assert result["average"] == pytest.approx(mean(expected.values()), abs=1e-9)
        else:
            assert result["average"] is None
