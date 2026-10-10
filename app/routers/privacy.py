"""GET /privacy: the privacy policy as a plain HTML page (linked from Google's/GitHub's consent screens).

Hard-coded text; keep it in sync with what the app really collects when that changes.
"""

from html import escape

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

from app.config import settings

router = APIRouter(tags=["legal"])

LAST_UPDATED = "10 października 2026"
REPOSITORY_ISSUES = "https://github.com/Lucjuszo/HackYeah_2026/issues"

_PAGE = """<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Polityka prywatności – Third Places</title>
<style>
  :root {{ color-scheme: light dark; --bg: #fdfcf9; --fg: #1f2328; --muted: #57606a; --line: #d8dee4; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg: #16181c; --fg: #e6e8eb; --muted: #9aa4af; --line: #30363d; }} }}
  body {{ margin: 0; background: var(--bg); color: var(--fg);
         font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }}
  main {{ max-width: 46rem; margin: 0 auto; padding: 2rem 1rem 4rem; }}
  h1 {{ font-size: 1.8rem; margin-bottom: .2rem; }}
  h2 {{ font-size: 1.15rem; margin-top: 2rem; padding-top: 1rem; border-top: 1px solid var(--line); }}
  .meta {{ color: var(--muted); margin-top: 0; }}
  a {{ color: inherit; }}
</style>
</head>
<body>
<main>
<h1>Polityka prywatności</h1>
<p class="meta">Third Places (thirdplaces.pl) · ostatnia aktualizacja: {updated}</p>

<p>Third Places to mapa miejsc do pracy i nauki poza domem. Ta strona wyjaśnia, jakie dane
zbieramy, po co i jak możesz nimi zarządzać. Przeglądanie mapy nie wymaga konta.</p>

<h2>1. Administrator danych</h2>
<p>Administratorem danych jest zespół projektu Third Places. Kontakt w sprawach prywatności:
{contact}.</p>

<h2>2. Jakie dane zbieramy</h2>
<ul>
  <li><strong>Dane konta</strong> – gdy logujesz się przez GitHub lub Google, otrzymujemy
    identyfikator konta u tego dostawcy, imię i nazwisko (lub nazwę użytkownika), adres e-mail
    (tylko jeśli dostawca potwierdził go jako zweryfikowany) oraz adres zdjęcia profilowego.
    Nie dostajemy Twojego hasła ani dostępu do innych danych w GitHubie czy Google.</li>
  <li><strong>Treści, które dodajesz</strong> – miejsca, oceny, komentarze, polubienia i zdjęcia,
    razem z informacją, kto i kiedy je dodał.</li>
  <li><strong>Lokalizacja</strong> – tylko jeśli na to pozwolisz w przeglądarce lub telefonie.
    Służy do pokazania miejsc w pobliżu i czasu dojazdu. Nie zapisujemy jej na serwerze.</li>
  <li><strong>Dane techniczne</strong> – nie prowadzimy logów odwiedzin. Logi błędów serwera mogą
    zawierać informacje techniczne o zapytaniu i są automatycznie nadpisywane.</li>
</ul>

<h2>3. Po co je przetwarzamy</h2>
<ul>
  <li>logowanie i utrzymanie konta oraz przypisanie Twoich treści do Ciebie
    (art. 6 ust. 1 lit. b RODO – świadczenie usługi),</li>
  <li>moderacja treści, ochrona przed nadużyciami i bezpieczeństwo serwisu
    (art. 6 ust. 1 lit. f RODO – prawnie uzasadniony interes),</li>
  <li>pokazanie miejsc w pobliżu na podstawie lokalizacji (art. 6 ust. 1 lit. a RODO – zgoda,
    którą możesz w każdej chwili cofnąć w ustawieniach urządzenia).</li>
</ul>
<p>Nie sprzedajemy danych, nie wyświetlamy reklam i nie profilujemy użytkowników.</p>

<h2>4. Co jest publiczne</h2>
<p>Dodane miejsca, oceny, komentarze i zdjęcia są widoczne dla wszystkich odwiedzających razem
z Twoją nazwą. Adres e-mail nie jest nigdy pokazywany innym użytkownikom.</p>

<h2>5. Komu przekazujemy dane</h2>
<p>Korzystamy z usług zewnętrznych, które przetwarzają dane w naszym imieniu lub na Twoje żądanie:</p>
<ul>
  <li><strong>GitHub, Google</strong> – logowanie (zgodnie z ich własnymi politykami prywatności),</li>
  <li><strong>MongoDB Atlas</strong> – baza danych,</li>
  <li><strong>Cloudinary</strong> – przechowywanie i wyświetlanie zdjęć,</li>
  <li><strong>Cloudflare</strong> – przesyłanie ruchu do serwera i ochrona przed atakami,</li>
  <li><strong>OpenStreetMap</strong> – kafelki mapy, wyszukiwanie adresów (Nominatim) i wyznaczanie
    czasu dojazdu (routing.openstreetmap.de); te usługi widzą Twój adres IP oraz – przy czasie
    dojazdu – przybliżoną lokalizację.</li>
</ul>
<p>Część tych dostawców może przetwarzać dane poza Europejskim Obszarem Gospodarczym na podstawie
standardowych klauzul umownych lub innych zabezpieczeń przewidzianych w RODO.</p>

<h2>6. Pliki cookie i pamięć przeglądarki</h2>
<p>Nie używamy cookies reklamowych ani analitycznych. Podczas logowania serwer ustawia krótkotrwałe
ciasteczko (ważne 10 minut) chroniące przed podszyciem się pod logowanie. Po zalogowaniu token
dostępu jest przechowywany w pamięci przeglądarki lub aplikacji i wygasa po {token_lifetime}.</p>

<h2>7. Jak długo przechowujemy dane</h2>
<p>Dane konta i Twoje treści przechowujemy, dopóki konto istnieje. Na Twoją prośbę usuniemy konto
wraz z danymi osobowymi; treści mogą zostać usunięte lub zanonimizowane.</p>

<h2>8. Twoje prawa</h2>
<p>Masz prawo dostępu do swoich danych, ich sprostowania, usunięcia, ograniczenia przetwarzania,
przeniesienia, sprzeciwu wobec przetwarzania oraz cofnięcia zgody. Aby skorzystać z tych praw,
skontaktuj się z nami ({contact_short}). Przysługuje Ci też skarga do Prezesa Urzędu Ochrony
Danych Osobowych (uodo.gov.pl).</p>
<p>Dostęp aplikacji do konta możesz w każdej chwili odebrać w ustawieniach GitHuba
(Settings → Applications) lub Google (myaccount.google.com → Bezpieczeństwo → Połączenia z aplikacjami).</p>

<h2>9. Dzieci</h2>
<p>Serwis nie jest skierowany do osób poniżej 16 roku życia.</p>

<h2>10. Zmiany</h2>
<p>Jeśli zmienimy tę politykę, zaktualizujemy datę na górze strony.</p>
</main>
</body>
</html>
"""


def _lifetime() -> str:
    """JWT_TTL_MINUTES in words, e.g. "24 godz." or "90 min"."""
    minutes = settings.jwt_ttl_minutes
    return f"{minutes // 60} godz." if minutes % 60 == 0 else f"{minutes} min"


def render_policy() -> str:
    if settings.privacy_contact_email:
        email = escape(settings.privacy_contact_email)
        contact = f'<a href="mailto:{email}">{email}</a>'
        contact_short = contact
    else:
        contact = f'zgłoszenie na <a href="{REPOSITORY_ISSUES}">GitHubie projektu</a>'
        contact_short = f'<a href="{REPOSITORY_ISSUES}">GitHub</a>'
    return _PAGE.format(
        updated=LAST_UPDATED, contact=contact, contact_short=contact_short, token_lifetime=_lifetime()
    )


@router.get("/privacy", response_class=HTMLResponse)
async def privacy_policy() -> HTMLResponse:
    """Privacy policy (HTML page, Polish). Public, no login."""
    return HTMLResponse(render_policy(), headers={"Cache-Control": "public, max-age=3600"})
