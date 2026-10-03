import 'package:flutter_test/flutter_test.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/api/places_api.dart';
import 'package:miejscowki_map/ui/format.dart' as fmt;

import 'fake_backend.dart';

void main() {
  final apiUrl = Uri.parse('http://api.test/');

  group('format', () {
    test('odmiana liczebników', () {
      expect(fmt.placesCount(0), '0 miejsc');
      expect(fmt.placesCount(1), '1 miejsce');
      expect(fmt.placesCount(3), '3 miejsca');
      expect(fmt.placesCount(5), '5 miejsc');
      expect(fmt.placesCount(12), '12 miejsc');
      expect(fmt.placesCount(22), '22 miejsca');
      expect(fmt.placesCount(114), '114 miejsc');
      expect(fmt.commentsCount(2), '2 opinie');
      expect(fmt.ratingsCount(5), '5 ocen');
    });

    test('odległości', () {
      expect(fmt.distance(237), '240 m');
      expect(fmt.distance(1530), '1,5 km');
      expect(fmt.distance(25300), '25 km');
    });

    test('ceny', () {
      expect(fmt.priceLabel(const PriceRange(0, 30), '0-30'), '0–30 zł');
      expect(fmt.priceLabel(const PriceRange(0, 0), 'za darmo'), 'Bezpłatnie');
      expect(fmt.priceLabel(const PriceRange(60, null), '60+'), 'od 60 zł');
      expect(fmt.priceLabel(const PriceRange(20, 20), '20'), '20 zł');
      expect(fmt.priceLabel(null, 'tanio'), 'tanio');
      expect(fmt.priceLabel(null, null), isNull);
      expect(fmt.money(1450, 'PLN'), '14,50 zł');
    });

    test('status otwarcia', () {
      final now = DateTime(2026, 10, 7, 14, 30);
      PlaceSummary place({bool? open, DateTime? closes, DateTime? opens}) => PlaceSummary.fromJson(
        {
          ...summaryJson('p', 'X', openNow: open, closesAt: null, opensAt: null),
        },
        apiUrl: apiUrl,
      ).copyStatus(open, closes, opens);

      var s = fmt.openStatus(place(open: true, closes: DateTime(2026, 10, 7, 20)), now: now);
      expect((s.label, s.detail, s.open), ('Otwarte teraz', 'do 20:00', true));

      s = fmt.openStatus(place(open: true, closes: DateTime(2026, 10, 8, 2)), now: now);
      expect(s.detail, 'do jutro 2:00');

      s = fmt.openStatus(place(open: true), now: now);
      expect(s.detail, 'całą dobę');

      s = fmt.openStatus(place(open: false, opens: DateTime(2026, 10, 7, 16, 5)), now: now);
      expect((s.label, s.detail), ('Zamknięte', 'otwiera 16:05'));

      s = fmt.openStatus(place(open: false, opens: DateTime(2026, 10, 12, 9)), now: now);
      expect(s.detail, 'otwiera w pon. 9:00');

      s = fmt.openStatus(place(open: null), now: now);
      expect((s.label, s.open), ('Godziny nieznane', null));
    });

    test('daty opinii', () {
      final now = DateTime(2026, 10, 7, 12);
      expect(fmt.date(DateTime(2026, 10, 7, 8), now: now), 'dzisiaj');
      expect(fmt.date(DateTime(2026, 10, 6, 23), now: now), 'wczoraj');
      expect(fmt.date(DateTime(2026, 9, 3), now: now), '3 września');
      expect(fmt.date(DateTime(2025, 12, 24), now: now), '24 grudnia 2025');
    });
  });

  group('modele', () {
    test('względne adresy zdjęć są uzupełniane adresem API', () {
      final place = PlaceSummary.fromJson(summaryJson('p', 'X'), apiUrl: apiUrl);
      expect(place.thumbnailUrl, 'http://api.test/media/places/p/thumb.webp');

      final absolute = PlaceSummary.fromJson(
        summaryJson('p', 'X', thumbnail: 'https://cdn.example.com/a.webp'),
        apiUrl: apiUrl,
      );
      expect(absolute.thumbnailUrl, 'https://cdn.example.com/a.webp');
    });

    test('pełne miejsce: zdjęcia, menu, godziny', () {
      final place = Place.fromJson(placeJson('p1', 'Kawiarnia'), apiUrl: apiUrl);
      expect(place.photos, hasLength(2));
      expect(place.photos.first.thumbnailUrl, 'http://api.test/media/places/p1/ph0_thumb.webp');
      expect(place.photos.first.full.url, 'http://api.test/media/places/p1/ph0.webp');
      expect(place.menu.map((m) => m.name), ['Flat white', 'Sernik']);
      expect(place.openingHours!.forDay(0).single.open, '08:00');
      expect(place.openingHours!.forDay(6), isEmpty);
      expect(place.atmosphere, Atmosphere.quiet);
      expect(place.priceRange!.max, 30);
    });

    test('brakujące pola są bezpieczne', () {
      final place = PlaceSummary.fromJson(
        summaryJson('p', 'X', average: null, count: 0, thumbnail: null, priceRange: null, amenities: const {}),
        apiUrl: apiUrl,
      );
      expect(place.rating.average, isNull);
      expect(place.thumbnailUrl, isNull);
      expect(place.priceRange, isNull);
      expect(place.amenities.wifi, isNull);
    });
  });

  group('zapytanie', () {
    test('parametry filtrów', () {
      const query = PlacesQuery(
        bounds: GeoBounds(south: 49.96, west: 19.79, north: 50.13, east: 20.22),
        text: '  kawa ',
        wifi: true,
        openNow: true,
        atmosphere: Atmosphere.chatty,
        minRating: 4,
        maxPrice: 30,
        sort: PlaceSort.rating,
      );
      expect(query.toQueryParameters(), {
        'bbox': '49.96000,19.79000,50.13000,20.22000',
        'q': 'kawa',
        'wifi': 'true',
        'open_now': 'true',
        'atmosphere': 'chatty',
        'min_rating': '4.0',
        'max_price': '30',
        'sort': 'rating',
      });
    });

    test('w promieniu', () {
      const query = PlacesQuery(near: LatLon(50.06, 19.94), radiusM: 2000, sort: PlaceSort.distance);
      expect(query.toQueryParameters(), {
        'lat': '50.06000',
        'lon': '19.94000',
        'radius_m': '2000',
        'sort': 'distance',
      });
    });

    test('błędy API mają czytelne komunikaty', () async {
      final backend = FakeBackend()..failPlaces = true;
      expect(
        () => backend.api().searchPlaces(const PlacesQuery()),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('Serwer'))),
      );
      expect(
        () => backend.api().getPlace('nope'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('liczba wyników z nagłówka X-Total-Count', () async {
      final page = await FakeBackend().api().getComments('p1', limit: 2);
      expect(page.items, hasLength(2));
      expect(page.total, 3);
    });
  });
}

extension on PlaceSummary {
  PlaceSummary copyStatus(bool? open, DateTime? closes, DateTime? opens) => PlaceSummary(
    id: id,
    name: name,
    address: address,
    location: location,
    amenities: amenities,
    rating: rating,
    openNow: open,
    closesAt: closes,
    opensAt: opens,
  );
}
