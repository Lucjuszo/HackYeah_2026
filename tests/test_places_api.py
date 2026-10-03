from bson import ObjectId

# Distances from the Main Square in Kraków (50.0617, 19.9373).
RYNEK = {"lat": 50.0617, "lon": 19.9373}
NEAR_200M = {"lat": 50.0633, "lon": 19.9396}
NEAR_800M = {"lat": 50.0545, "lon": 19.9353}
WARSAW = {"lat": 52.2297, "lon": 21.0122}


def add_place(client, payload, name, coordinates, **extra):
    response = client.post("/places", json={**payload, "name": name, "coordinates": coordinates, **extra})
    assert response.status_code == 201, response.text
    return response.json()


def test_health(client):
    assert client.get("/health").json() == {"status": "ok", "mongo": "ok"}


class TestCreatePlace:
    def test_returns_created_place(self, created_place, place_payload):
        assert ObjectId.is_valid(created_place["id"])
        assert created_place["name"] == place_payload["name"]
        assert created_place["coordinates"] == place_payload["coordinates"]
        assert created_place["amenities"] == place_payload["amenities"]
        assert created_place["opening_hours"]["periods"][0] == {"day": 0, "open": "08:00", "close": "20:00"}
        assert created_place["features"] == place_payload["features"]
        assert created_place["photos"] == []
        assert created_place["created_at"] == created_place["updated_at"]

    def test_stored_document_shape(self, created_place, db):
        doc = db.places.find_one({"_id": ObjectId(created_place["id"])})
        # GeoJSON order is [lon, lat]
        assert doc["location"] == {"type": "Point", "coordinates": [19.9396, 50.0633]}
        assert "coordinates" not in doc
        assert doc["atmosphere"] == "quiet"
        assert doc["amenities"]["wifi"] is True
        assert "osm" not in doc  # omitted, not null, so the partial unique index skips it

    def test_minimal(self, client, minimal_payload):
        response = client.post("/places", json=minimal_payload)
        assert response.status_code == 201
        body = response.json()
        assert body["amenities"]["wifi"] is None
        assert body["opening_hours"] is None

    def test_validation_error(self, client, minimal_payload):
        response = client.post("/places", json={**minimal_payload, "atmosphere": "loud"})
        assert response.status_code == 422

    def test_duplicate_osm_ref_conflicts(self, client, minimal_payload):
        osm = {"type": "node", "id": 42}
        assert client.post("/places", json={**minimal_payload, "osm": osm}).status_code == 201
        response = client.post("/places", json={**minimal_payload, "name": "Other", "osm": osm})
        assert response.status_code == 409
        assert "node/42" in response.json()["detail"]

    def test_same_osm_id_different_type_allowed(self, client, minimal_payload):
        assert client.post("/places", json={**minimal_payload, "osm": {"type": "node", "id": 42}}).status_code == 201
        assert client.post("/places", json={**minimal_payload, "osm": {"type": "way", "id": 42}}).status_code == 201

    def test_many_places_without_osm_allowed(self, client, minimal_payload):
        for _ in range(3):
            assert client.post("/places", json=minimal_payload).status_code == 201


class TestGetPlace:
    def test_found(self, client, created_place):
        response = client.get(f"/places/{created_place['id']}")
        assert response.status_code == 200
        assert response.json() == created_place

    def test_not_found(self, client):
        assert client.get(f"/places/{ObjectId()}").status_code == 404

    def test_invalid_id(self, client):
        assert client.get("/places/not-an-id").status_code == 404


class TestListPlaces:
    def test_empty(self, client):
        assert client.get("/places").json() == []

    def test_lists_all(self, client, minimal_payload):
        for name in ("A", "B", "C"):
            add_place(client, minimal_payload, name, RYNEK)
        assert sorted(p["name"] for p in client.get("/places").json()) == ["A", "B", "C"]

    def test_near_filters_by_radius_and_sorts_by_distance(self, client, minimal_payload):
        add_place(client, minimal_payload, "far", NEAR_800M)
        add_place(client, minimal_payload, "warsaw", WARSAW)
        add_place(client, minimal_payload, "close", NEAR_200M)

        response = client.get("/places", params={**RYNEK, "radius_m": 1000})
        assert [p["name"] for p in response.json()] == ["close", "far"]

        response = client.get("/places", params={**RYNEK, "radius_m": 500})
        assert [p["name"] for p in response.json()] == ["close"]

    def test_power_outlets_filter(self, client, minimal_payload):
        add_place(client, minimal_payload, "yes", RYNEK, amenities={"power_outlets": True})
        add_place(client, minimal_payload, "no", RYNEK, amenities={"power_outlets": False})
        add_place(client, minimal_payload, "unknown", RYNEK)

        assert [p["name"] for p in client.get("/places?power_outlets=true").json()] == ["yes"]
        assert [p["name"] for p in client.get("/places?power_outlets=false").json()] == ["no"]

    def test_pagination(self, client, minimal_payload):
        for i in range(5):
            add_place(client, minimal_payload, f"p{i}", RYNEK)
        first = client.get("/places?limit=2").json()
        rest = client.get("/places?limit=10&skip=2").json()
        assert len(first) == 2
        assert len(rest) == 3
        assert {p["id"] for p in first}.isdisjoint(p["id"] for p in rest)

    def test_lat_without_lon_rejected(self, client):
        assert client.get("/places?lat=50").status_code == 422

    def test_invalid_params_rejected(self, client):
        assert client.get("/places?limit=0").status_code == 422
        assert client.get("/places?limit=201").status_code == 422
        assert client.get("/places?skip=-1").status_code == 422
        assert client.get("/places?lat=91&lon=0").status_code == 422
        assert client.get("/places?lat=50&lon=19&radius_m=0").status_code == 422


def test_indexes_created(client, db):
    indexes = {ix["name"]: ix for ix in db.places.list_indexes()}
    assert any(ix["key"].get("location") == "2dsphere" for ix in indexes.values())
    osm_index = next(ix for ix in indexes.values() if "osm.id" in ix["key"])
    assert osm_index["unique"] is True
