# Focus Map – frontend (Flutter)

Mapa miejscówek w całej Polsce: mapa OpenStreetMap (`flutter_map`), lista i szczegóły miejsc z backendu
(`app/`), filtry, wyszukiwanie miasta/adresu i „Moja lokalizacja”. Dodawanie miejsca (przycisk +) loguje przez Google.

```bash
# backend (katalog główny repo)
fastapi dev app/main.py

# front – w przeglądarce
cd frontend
flutter pub get
flutter run -d chrome --dart-define=API_URL=http://localhost:8000

# testy
flutter test
```

- `API_URL` – adres backendu (domyślnie `http://localhost:8000`).
- Wersja Windows (`flutter run -d windows`) wymaga włączonego Trybu dewelopera w Windows (pluginy potrzebują symlinków).
- Kontrakt API i parametry wyszukiwania: [`docs/FRONTEND.md`](../docs/FRONTEND.md).

Struktura: `lib/api/` (modele + klient HTTP), `lib/services/` (GPS), `lib/ui/` (ekrany i widżety), `lib/main.dart` (mapa i lista).
