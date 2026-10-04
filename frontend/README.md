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

# Android emulator – 10.0.2.2 oznacza komputer hosta
flutter run -d emulator-5554 --dart-define=API_URL=http://10.0.2.2:8000

# Telefon fizyczny – komputer i telefon muszą być w tej samej sieci Wi-Fi.
# Zastąp adres adresem IPv4 komputera, np. 10.250.161.196.
flutter run -d <ID_TELEFONU> --dart-define=API_URL=http://<IP_KOMPUTERA>:8000

# testy
flutter test
```

- `API_URL` – adres backendu (domyślnie `http://localhost:8000`). Na telefonie nie używaj
  `localhost`, bo oznacza on telefon; użyj adresu LAN komputera. Na emulatorze Androida użyj
  `10.0.2.2`.
- CORS dotyczy przeglądarki (Flutter Web), nie natywnej aplikacji Android. Jeśli telefon nadal
  nie łączy się po adresie LAN, zezwól na połączenia TCP na porcie `8000` w Zaporze Windows
  i upewnij się, że sieć Wi-Fi nie izoluje urządzeń klienckich.
- Wersja Windows (`flutter run -d windows`) wymaga włączonego Trybu dewelopera w Windows (pluginy potrzebują symlinków).
- Kontrakt API i parametry wyszukiwania: [`docs/FRONTEND.md`](../docs/FRONTEND.md).

Struktura: `lib/api/` (modele + klient HTTP), `lib/services/` (GPS), `lib/ui/` (ekrany i widżety), `lib/main.dart` (mapa i lista).
