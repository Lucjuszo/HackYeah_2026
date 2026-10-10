from html.parser import HTMLParser

from app.config import settings
from app.routers.privacy import REPOSITORY_ISSUES
from tests.helpers import ANONYMOUS


def get_policy(client):
    return client.get("/privacy", headers=ANONYMOUS)


def test_public_html_page(client):
    response = get_policy(client)
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "charset=utf-8" in response.headers["content-type"]
    assert response.headers["cache-control"] == "public, max-age=3600"
    assert "<title>Polityka prywatności – Third Places</title>" in response.text


def test_well_formed(client):
    """Every tag that is opened is closed (no broken markup from the template)."""
    void = {"meta", "br", "hr", "img", "link", "input"}

    class Checker(HTMLParser):
        stack: list[str] = []

        def handle_starttag(self, tag, attrs):
            if tag not in void:
                self.stack.append(tag)

        def handle_endtag(self, tag):
            assert self.stack and self.stack.pop() == tag, f"unexpected </{tag}>"

    checker = Checker()
    checker.stack = []
    checker.feed(get_policy(client).text)
    assert checker.stack == []


def test_covers_what_the_app_collects(client):
    text = get_policy(client).text
    for phrase in ("GitHub", "Google", "e-mail", "Lokalizacja", "Cloudinary", "MongoDB Atlas",
                   "OpenStreetMap", "Cloudflare", "RODO", "uodo.gov.pl", "Twoje prawa"):
        assert phrase in text, phrase


def test_no_unfilled_placeholders(client):
    text = get_policy(client).text
    assert "{" not in text.split("</style>", 1)[1]


def test_contact_defaults_to_github_issues(client, monkeypatch):
    monkeypatch.setattr(settings, "privacy_contact_email", None)
    text = get_policy(client).text
    assert f'href="{REPOSITORY_ISSUES}"' in text
    assert "mailto:" not in text


def test_configured_contact_email(client, monkeypatch):
    monkeypatch.setattr(settings, "privacy_contact_email", "privacy@thirdplaces.pl")
    text = get_policy(client).text
    assert '<a href="mailto:privacy@thirdplaces.pl">privacy@thirdplaces.pl</a>' in text
    assert REPOSITORY_ISSUES not in text


def test_contact_email_is_escaped(client, monkeypatch):
    monkeypatch.setattr(settings, "privacy_contact_email", '"><script>alert(1)</script>')
    text = get_policy(client).text
    assert "<script>" not in text
    assert "&lt;script&gt;" in text


def test_token_lifetime_follows_settings(client, monkeypatch):
    assert "wygasa po 24 godz." in get_policy(client).text  # default JWT_TTL_MINUTES
    monkeypatch.setattr(settings, "jwt_ttl_minutes", 90)
    assert "wygasa po 90 min" in get_policy(client).text

