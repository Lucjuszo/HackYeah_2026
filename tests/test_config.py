import pytest

from app.config import Settings

ENV_VARS = ("USE_REMOTE_MONGO", "MONGODB_URI", "MONGODB_USERNAME", "MONGODB_PASSWORD", "MONGO_URI", "MONGO_DB")


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    # conftest forces the test container via env vars; these tests check the real defaults.
    for name in ENV_VARS:
        monkeypatch.delenv(name, raising=False)


def make(**values) -> Settings:
    # _env_file=None: don't read the developer's .env; only explicit values count.
    return Settings(_env_file=None, **values)


def test_remote_is_default():
    assert make().use_remote_mongo is True


def test_local_container():
    uri, kwargs = make(use_remote_mongo=False, mongo_uri="mongodb://root:example@localhost:27017").mongo_connection()
    assert uri == "mongodb://root:example@localhost:27017"
    assert kwargs == {}


def test_remote_ignores_local_uri():
    settings = make(mongodb_uri="mongodb+srv://u:p@cluster.example.net/", mongo_uri="mongodb://local")
    assert settings.mongo_connection() == ("mongodb+srv://u:p@cluster.example.net/", {})


def test_remote_credentials_in_uri_win():
    settings = make(mongodb_uri="mongodb+srv://u:p@cluster.example.net/", mongodb_username="other", mongodb_password="x")
    assert settings.mongo_connection() == ("mongodb+srv://u:p@cluster.example.net/", {})


def test_remote_credentials_from_separate_variables():
    settings = make(mongodb_uri="mongodb+srv://cluster.example.net/?appName=x", mongodb_username="u", mongodb_password="p")
    uri, kwargs = settings.mongo_connection()
    assert uri == "mongodb+srv://cluster.example.net/?appName=x"
    assert kwargs == {"username": "u", "password": "p"}


def test_remote_without_uri_fails_clearly():
    with pytest.raises(RuntimeError, match="USE_REMOTE_MONGO=false"):
        make().mongo_connection()


@pytest.mark.parametrize("value", ["false", "False", "0", "no"])
def test_flag_parsed_from_env(monkeypatch, value):
    monkeypatch.setenv("USE_REMOTE_MONGO", value)
    assert make().use_remote_mongo is False


def test_secrets_not_in_repr():
    settings = make(mongodb_uri="mongodb+srv://u:secret@cluster.example.net/", mongodb_password="secret")
    assert "secret" not in repr(settings)
    assert "secret" not in settings.mongo_target()


def test_unknown_env_keys_ignored(tmp_path):
    env = tmp_path / ".env"
    env.write_text("SOMETHING_ELSE=1\nMONGO_DB=from_file\n", encoding="utf-8")
    assert Settings(_env_file=env).mongo_db == "from_file"
