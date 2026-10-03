import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/api/places_api.dart';

http.Response _json(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

void main() {
  group('PlacesQuery.toQueryParameters', () {
    test('pusty filtr nie wysyła parametrów', () {
      expect(const PlacesQuery().toQueryParameters(), isEmpty);
    });

    test('bbox w kolejności S,W,N,E', () {
      const query = PlacesQuery(
        bounds: GeoBounds(south: 50, west: 19.9, north: 50.1, east: 20),
      );
      expect(query.toQueryParameters(), {
        'bbox': '50.00000,19.90000,50.10000,20.00000',
      });
    });

    test('wszystkie filtry', () {
      const query = PlacesQuery(
        near: LatLon(50.061, 19.937),
        radiusM: 1500,
        text: '  kawa  ',
        wifi: true,
        powerOutlets: true,
        openNow: true,
        atmosphere: Atmosphere.chatty,
        minRating: 4,
        minPrice: 0,
        maxPrice: 30,
        sort: PlaceSort.rating,
      );
      expect(query.toQueryParameters(), {
        'lat': '50.06100',
        'lon': '19.93700',
        'radius_m': '1500',
        'q': 'kawa',
        'wifi': 'true',
        'power_outlets': 'true',
        'open_now': 'true',
        'atmosphere': 'chatty',
        'min_rating': '4.0',
        'min_price': '0',
        'max_price': '30',
        'sort': 'rating',
      });
    });

    test('radius bez near i pusty tekst są pomijane', () {
      expect(const PlacesQuery(radiusM: 500, text: '   ').toQueryParameters(), isEmpty);
    });
  });

  group('PlacesApi', () {
    late http.Request lastRequest;

    PlacesApi api(http.Response Function(http.Request) handler) => PlacesApi(
      baseUrl: 'http://api.test',
      client: MockClient((request) async {
        lastRequest = request;
        return handler(request);
      }),
    );

    test('searchPlaces wysyła filtry i czyta X-Total-Count', () async {
      final page = await api(
        (_) => _json(
          [
            {
              'id': 'a',
              'name': 'Żabka Café',
              'address': {'city': 'Kraków'},
              'coordinates': {'lat': 50.0, 'lon': 19.9},
              'amenities': <String, dynamic>{},
            },
          ],
          headers: {'x-total-count': '42'},
        ),
      ).searchPlaces(const PlacesQuery(wifi: true), limit: 10);

      expect(lastRequest.url.path, '/places/summary');
      expect(lastRequest.url.queryParameters, {'wifi': 'true', 'limit': '10'});
      expect(page.total, 42);
      expect(page.items.single.name, 'Żabka Café');
    });

    test('bez X-Total-Count total = liczba elementów', () async {
      final page = await api((_) => _json([])).searchPlaces(const PlacesQuery());
      expect(page.total, 0);
    });

    test('getComments używa limit/skip i koduje id', () async {
      final page = await api(
        (_) => _json([
          {'id': 'c1', 'text': 'Super', 'created_at': '2026-10-01T10:00:00Z'},
        ]),
      ).getComments('a/b', limit: 5, skip: 10);

      expect(lastRequest.url.toString(), 'http://api.test/places/a%2Fb/comments?limit=5&skip=10');
      expect(page.items.single.text, 'Super');
    });

    test('geocode przycina tekst', () async {
      final results = await api((_) => _json([])).geocode('  Kraków ');
      expect(lastRequest.url.queryParameters, {'q': 'Kraków', 'limit': '6'});
      expect(results, isEmpty);
    });

    test('404 -> Nie znaleziono', () async {
      await expectLater(
        api((_) => _json({'detail': 'x'}, status: 404)).getPlace('x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', 'Nie znaleziono.'),
        ),
      );
    });

    test('422 pokazuje detail z backendu', () async {
      await expectLater(
        api((_) => _json({'detail': 'Zły bbox'}, status: 422)).getPlace('x'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Zły bbox')),
      );
    });

    test('500 -> komunikat o problemie serwera', () async {
      await expectLater(
        api((_) => http.Response('boom', 500)).getPlace('x'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            startsWith('Serwer ma chwilowy problem'),
          ),
        ),
      );
    });

    test('błąd sieci -> brak połączenia', () async {
      await expectLater(
        api((_) => throw http.ClientException('offline')).getPlace('x'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            startsWith('Brak połączenia'),
          ),
        ),
      );
    });
  });
}
