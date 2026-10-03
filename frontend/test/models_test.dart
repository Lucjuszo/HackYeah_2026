import 'package:flutter_test/flutter_test.dart';

import 'package:miejscowki_map/api/models.dart';

final _apiUrl = Uri.parse('http://localhost:8000/');

Json _summaryJson() => {
  'id': 'abc',
  'name': 'Cafe Botanica',
  'address': {
    'city': 'Kraków',
    'street': 'Floriańska',
    'house_number': '15',
  },
  'coordinates': {'lat': 50, 'lon': 19.94},
  'amenities': {'wifi': true, 'power_outlets': false},
  'rating': {'average': 4.5, 'count': 12},
  'price_range': {'min': 10, 'max': null},
  'atmosphere': 'quiet',
  'thumbnail_url': '/media/abc/thumb.jpg',
  'photo_count': 3,
  'open_now': true,
  'closes_at': '2026-10-03T18:00:00Z',
  'distance_m': 240,
};

void main() {
  group('PlaceSummary.fromJson', () {
    test('parsuje pełny rekord', () {
      final place = PlaceSummary.fromJson(_summaryJson(), apiUrl: _apiUrl);

      expect(place.id, 'abc');
      expect(place.address.short, 'Floriańska 15, Kraków');
      expect(place.location.lat, 50.0);
      expect(place.amenities.wifi, isTrue);
      expect(place.amenities.powerOutlets, isFalse);
      expect(place.amenities.toilet, isNull);
      expect(place.rating.average, 4.5);
      expect(place.rating.count, 12);
      expect(place.priceRange!.max, isNull);
      expect(place.atmosphere, Atmosphere.quiet);
      expect(place.thumbnailUrl, 'http://localhost:8000/media/abc/thumb.jpg');
      expect(place.openNow, isTrue);
      expect(place.closesAt!.isUtc, isFalse);
      expect(place.distanceM, 240.0);
      expect(place.isMock, isFalse);
    });

    test('brakujące pola opcjonalne dostają wartości domyślne', () {
      final json = _summaryJson()
        ..remove('rating')
        ..remove('price_range')
        ..remove('photo_count')
        ..['atmosphere'] = 'unknown';
      final place = PlaceSummary.fromJson(json, apiUrl: _apiUrl);

      expect(place.rating.average, isNull);
      expect(place.rating.count, 0);
      expect(place.priceRange, isNull);
      expect(place.photoCount, 0);
      expect(place.atmosphere, isNull);
    });
  });

  test('Address.short bez ulicy to samo miasto', () {
    expect(const Address(city: 'Gdańsk').short, 'Gdańsk');
  });

  test('Place.fromJson parsuje godziny, menu i zdjęcia', () {
    final place = Place.fromJson({
      ..._summaryJson(),
      'opening_hours': {
        'always_open': false,
        'periods': [
          {'day': 0, 'open': '08:00', 'close': '16:00'},
          {'day': 0, 'open': '18:00', 'close': '22:00'},
          {'day': 5, 'open': '10:00', 'close': '14:00'},
        ],
      },
      'features': ['ogródek'],
      'menu': [
        {'name': 'Latte', 'price': 1500},
      ],
      'photos': [
        {
          'id': 'ph1',
          'url': 'https://cdn.example.com/full.jpg',
          'width': 1200,
          'height': 800,
          'created_at': '2026-10-01T10:00:00Z',
        },
      ],
    }, apiUrl: _apiUrl);

    expect(place.openingHours!.forDay(0), hasLength(2));
    expect(place.openingHours!.forDay(6), isEmpty);
    expect(place.features, ['ogródek']);
    expect(place.menu.single.currency, 'PLN');
    expect(place.photos.single.thumbnailUrl, 'https://cdn.example.com/full.jpg');
  });

  test('GeocodeResult.fromJson mapuje bbox [S, N, W, E]', () {
    final result = GeocodeResult.fromJson({
      'name': 'Kraków',
      'display_name': 'Kraków, małopolskie, Polska',
      'lat': 50.06,
      'lon': 19.94,
      'kind': 'city',
      'bbox': [49.97, 50.13, 19.79, 20.22],
    });

    expect(result.bounds!.south, 49.97);
    expect(result.bounds!.north, 50.13);
    expect(result.bounds!.west, 19.79);
    expect(result.bounds!.east, 20.22);
  });

  test('resolveUrl', () {
    expect(resolveUrl(_apiUrl, null), isNull);
    expect(resolveUrl(_apiUrl, '/media/x.jpg'), 'http://localhost:8000/media/x.jpg');
    expect(resolveUrl(_apiUrl, 'https://a.b/x.jpg'), 'https://a.b/x.jpg');
  });
}
