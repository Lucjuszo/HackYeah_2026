import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/api/places_api.dart';
import 'package:miejscowki_map/services/location_service.dart';

Json summaryJson(
  String id,
  String name, {
  double lat = 50.0617,
  double lon = 19.9373,
  double? average = 4.6,
  int count = 12,
  bool? openNow = true,
  String? closesAt = '2026-10-07T20:00:00+02:00',
  String? opensAt,
  Json amenities = const {'wifi': true, 'power_outlets': true},
  String? thumbnail = '/media/places/p/thumb.webp',
  int photoCount = 2,
  Json? priceRange = const {'min': 0, 'max': 30},
  double? distance,
}) => {
  'id': id,
  'name': name,
  'address': {'street': 'Floriańska', 'house_number': '15', 'city': 'Kraków', 'country_code': 'pl'},
  'coordinates': {'lat': lat, 'lon': lon},
  'amenities': amenities,
  'usage_price': '0-30',
  'price_range': priceRange,
  'atmosphere': 'quiet',
  'rating': {'average': average, 'count': count},
  'thumbnail_url': thumbnail,
  'photo_count': photoCount,
  'open_now': openNow,
  'closes_at': closesAt,
  'opens_at': opensAt,
  'is_mock': false,
  'distance_m': distance,
};

Json placeJson(String id, String name) => {
  ...summaryJson(id, name),
  'opening_hours': {
    'always_open': false,
    'periods': [
      for (var d = 0; d < 5; d++) {'day': d, 'open': '08:00', 'close': '20:00'},
    ],
  },
  'features': ['Pokoje wygłuszane'],
  'menu': [
    {'name': 'Flat white', 'category': 'Kawa', 'price': 1400, 'currency': 'PLN'},
    {'name': 'Sernik', 'category': 'Ciasta', 'price': 1600, 'currency': 'PLN'},
  ],
  'photos': [
    for (var i = 0; i < 2; i++)
      {
        'id': 'ph$i',
        'url': '/media/places/$id/ph$i.webp',
        'content_type': 'image/webp',
        'width': 1600,
        'height': 900,
        'size': 1000,
        'thumbnail': {'url': '/media/places/$id/ph${i}_thumb.webp', 'width': 400, 'height': 225, 'size': 100},
        'uploaded_by_name': 'Anna',
        'created_at': '2026-10-01T10:00:00Z',
      },
  ],
  'mock_fields': <String>[],
};

Json commentJson(int i) => {
  'id': 'c$i',
  'place_id': 'p1',
  'user_id': 'u$i',
  'user_name': 'Użytkownik $i',
  'text': 'Opinia numer $i',
  'created_at': '2026-09-2${i % 10}T10:00:00Z',
};

/// In-memory backend: answers the public endpoints and records every request.
class FakeBackend {
  FakeBackend({
    List<Json>? places,
    this.comments = 3,
    this.failPlaces = false,
  }) : places = places ??
           [summaryJson('p1', 'Kawiarnia Pod Kodem'), summaryJson('p2', 'Czytelnia', lat: 52.2297, lon: 21.0122, average: 3.9, openNow: false, opensAt: '2026-10-08T09:00:00+02:00', closesAt: null)];

  List<Json> places;
  int comments;
  bool failPlaces;
  List<Json> geocodeResults = [
    {
      'name': 'Gdańsk',
      'display_name': 'Gdańsk, województwo pomorskie, Polska',
      'lat': 54.352,
      'lon': 18.6466,
      'kind': 'city',
      'bbox': [54.27, 54.45, 18.43, 18.95],
    },
  ];
  final List<Uri> requests = [];

  List<Uri> get searches => requests.where((u) => u.path == '/places/summary').toList();

  Uri get lastSearch => searches.last;

  http.Response _json(Object body, {Map<String, String> headers = const {}}) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'content-type': 'application/json', ...headers},
  );

  late final http.Client client = MockClient((http.Request request) async {
    final uri = request.url;
    requests.add(uri);
    final path = uri.pathSegments;
    if (uri.path == '/places/summary') {
      if (failPlaces) return http.Response('{"detail": "boom"}', 500);
      // Like the real backend: only places inside the visible map area.
      final bbox = uri.queryParameters['bbox']?.split(',').map(double.parse).toList();
      final visible = bbox == null
          ? places
          : places.where((p) {
              final c = p['coordinates'] as Json;
              final (lat, lon) = (c['lat'] as double, c['lon'] as double);
              return lat >= bbox[0] && lat <= bbox[2] && lon >= bbox[1] && lon <= bbox[3];
            }).toList();
      return _json(visible, headers: {'x-total-count': '${visible.length}'});
    }
    if (uri.path == '/geocode') return _json(geocodeResults);
    if (path.length == 3 && path[0] == 'places' && path[2] == 'comments') {
      final limit = int.parse(uri.queryParameters['limit'] ?? '20');
      final skip = int.parse(uri.queryParameters['skip'] ?? '0');
      final page = [for (var i = skip; i < comments && i < skip + limit; i++) commentJson(i)];
      return _json(page, headers: {'x-total-count': '$comments'});
    }
    if (path.length == 2 && path[0] == 'places') {
      final summary = places.firstWhere((p) => p['id'] == path[1], orElse: () => {});
      if (summary.isEmpty) return http.Response('{"detail": "Place not found"}', 404);
      return _json(placeJson(path[1], summary['name'] as String));
    }
    return http.Response('{"detail": "Not Found"}', 404);
  });

  PlacesApi api() => PlacesApi(baseUrl: 'http://api.test', client: client);
}

class FakeLocationService implements LocationService {
  FakeLocationService({this.result, this.failure});

  final LatLon? result;
  final LocationFailure? failure;

  @override
  Future<LatLon> currentLocation() async {
    if (failure != null) throw failure!;
    return result!;
  }
}
