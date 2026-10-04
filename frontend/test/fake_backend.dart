import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:latlong2/latlong.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/api/places_api.dart';
import 'package:miejscowki_map/auth/auth.dart';
import 'package:miejscowki_map/services/location_service.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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
        // The first one is the test user's own: they may delete it.
        'uploaded_by': i == 0 ? 'me' : 'anna',
        'uploaded_by_name': i == 0 ? 'Ja Testowy' : 'Anna',
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

/// In-memory backend: answers like the real API (public + logged-in endpoints) and records every request.
class FakeBackend {
  FakeBackend({
    List<Json>? places,
    this.comments = 3,
    this.failPlaces = false,
  }) : places = places ??
           [summaryJson('p1', 'Kawiarnia Pod Kodem'), summaryJson('p2', 'Czytelnia', lat: 52.2297, lon: 21.0122, average: 3.9, openNow: false, opensAt: '2026-10-08T09:00:00+02:00', closesAt: null)];

  List<Json> places;

  /// Comments every place starts with.
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

  /// Bodies of POST /places.
  final List<Json> created = [];

  /// (place id, file name) of every POST /places/{id}/photos.
  final List<(String, String)> uploadedPhotos = [];

  /// (place id, photo id) of every DELETE /places/{id}/photos/{photoId}.
  final List<(String, String)> deletedPhotos = [];

  /// Status to answer photo uploads with instead of 201.
  int? photoUploadError;

  /// The only token the logged-in endpoints accept.
  String validToken = FakeOAuthLauncher.token;
  static const Json me = {'id': 'me', 'name': 'Ja Testowy', 'role': 'user'};
  List<String> providers = ['github', 'google'];

  /// place id -> the logged-in user's score.
  final Map<String, int> myRatings = {};
  final Map<String, List<Json>> _commentsByPlace = {};

  List<Json> commentsOf(String placeId) =>
      _commentsByPlace.putIfAbsent(placeId, () => [for (var i = 0; i < comments; i++) commentJson(i)]);

  /// GET /geocode/reverse answer; null = 404 (no address here).
  Json? reverseResult = {
    'street': 'Floriańska',
    'house_number': '15',
    'postcode': '31-019',
    'city': 'Kraków',
    'country_code': 'pl',
    'display_name': '15, Floriańska, Kraków, Polska',
  };

  List<Uri> get searches => requests.where((u) => u.path == '/places/summary').toList();

  Uri get lastSearch => searches.last;

  http.Response _json(Object body, {int status = 200, Map<String, String> headers = const {}}) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );

  http.Response _error(int status, String detail) => _json({'detail': detail}, status: status);

  late final http.Client client = MockClient((http.Request request) async {
    final uri = request.url;
    final method = request.method;
    requests.add(uri);
    final path = uri.pathSegments;
    final loggedIn = request.headers['Authorization'] == 'Bearer $validToken';
    Json body() => jsonDecode(request.body) as Json;

    if (uri.path == '/auth/providers') {
      return _json({
        'providers': [for (final p in providers) {'name': p, 'login_url': 'http://api.test/auth/$p/login'}],
        'dev_login': false,
      });
    }
    if (uri.path == '/auth/me') return loggedIn ? _json(me) : _error(401, 'Invalid or expired token');

    if (method == 'POST' && uri.path == '/places') {
      if (!loggedIn) return _error(401, 'Invalid or expired token');
      final data = body();
      created.add(data);
      final id = 'new${created.length}';
      places = [
        ...places,
        summaryJson(
          id,
          data['name'] as String,
          lat: (data['coordinates'] as Json)['lat'] as double,
          lon: (data['coordinates'] as Json)['lon'] as double,
          average: null,
          count: 0,
          openNow: null,
          closesAt: null,
          thumbnail: null,
          photoCount: 0,
          priceRange: null,
        ),
      ];
      return _json(placeJson(id, data['name'] as String), status: 201);
    }
    if (uri.path == '/geocode/reverse') {
      final result = reverseResult;
      return result == null ? _error(404, 'No address at this point') : _json(result);
    }
    if (uri.path == '/places/summary') {
      if (failPlaces) return _error(500, 'boom');
      // Like the real backend: only places inside the visible map area.
      final bbox = uri.queryParameters['bbox']?.split(',').map(double.parse).toList();
      final near = uri.queryParameters['lat'] == null
          ? null
          : LatLng(double.parse(uri.queryParameters['lat']!), double.parse(uri.queryParameters['lon']!));
      final radius = double.parse(uri.queryParameters['radius_m'] ?? '1000');
      final visible = places.where((p) {
        final c = p['coordinates'] as Json;
        final (lat, lon) = (c['lat'] as double, c['lon'] as double);
        if (near != null) return const Distance().as(LengthUnit.Meter, near, LatLng(lat, lon)) <= radius;
        if (bbox == null) return true;
        return lat >= bbox[0] && lat <= bbox[2] && lon >= bbox[1] && lon <= bbox[3];
      }).toList();
      return _json(visible, headers: {'x-total-count': '${visible.length}'});
    }
    if (uri.path == '/geocode') return _json(geocodeResults);

    // /places/{id}/ratings/me
    if (path.length == 4 && path[0] == 'places' && path[2] == 'ratings' && path[3] == 'me') {
      if (!loggedIn) return _error(401, 'Invalid or expired token');
      final placeId = path[1];
      switch (method) {
        case 'GET':
          final score = myRatings[placeId];
          return score == null ? _error(404, "You haven't rated this place") : _json({'score': score});
        case 'PUT':
          final score = body()['score'] as int;
          myRatings[placeId] = score;
          return _json({
            'rating': {'score': score},
            'summary': {'average': score.toDouble(), 'count': 13},
          });
        case 'DELETE':
          if (myRatings.remove(placeId) == null) return _error(404, "You haven't rated this place");
          return _json({'average': 4.6, 'count': 12});
      }
    }

    // /places/{id}/photos[/{photoId}]
    if (path.length >= 3 && path[0] == 'places' && path[2] == 'photos') {
      if (!loggedIn) return _error(401, 'Invalid or expired token');
      if (path.length == 3 && method == 'POST') {
        final error = photoUploadError;
        if (error != null) return _error(error, 'Upload failed');
        final name = RegExp(r'filename="([^"]*)"').firstMatch(latin1.decode(request.bodyBytes))?.group(1) ?? '';
        uploadedPhotos.add((path[1], name));
        final id = 'up${uploadedPhotos.length}';
        return _json({
          'id': id,
          'url': '/media/places/${path[1]}/$id.webp',
          'content_type': 'image/webp',
          'width': 1600,
          'height': 900,
          'size': 1000,
          'thumbnail': {'url': '/media/places/${path[1]}/${id}_thumb.webp', 'width': 400, 'height': 225, 'size': 100},
          'uploaded_by': me['id'],
          'uploaded_by_name': me['name'],
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }, status: 201);
      }
      if (path.length == 4 && method == 'DELETE') {
        deletedPhotos.add((path[1], path[3]));
        return http.Response('', 204);
      }
    }

    // /places/{id}/comments[/{commentId}]
    if (path.length >= 3 && path[0] == 'places' && path[2] == 'comments') {
      final list = commentsOf(path[1]);
      if (path.length == 3 && method == 'GET') {
        final limit = int.parse(uri.queryParameters['limit'] ?? '20');
        final skip = int.parse(uri.queryParameters['skip'] ?? '0');
        return _json(list.skip(skip).take(limit).toList(), headers: {'x-total-count': '${list.length}'});
      }
      if (!loggedIn) return _error(401, 'Invalid or expired token');
      if (path.length == 3 && method == 'POST') {
        final comment = {
          'id': 'c-new-${list.length}',
          'place_id': path[1],
          'user_id': me['id'],
          'user_name': me['name'],
          'text': body()['text'],
          'created_at': DateTime.now().toUtc().toIso8601String(),
        };
        list.insert(0, comment);
        return _json(comment, status: 201);
      }
      final i = list.indexWhere((c) => c['id'] == path[3]);
      if (i < 0) return _error(404, 'Comment not found');
      if (list[i]['user_id'] != me['id']) return _error(403, 'Only the author or an admin can change this comment');
      if (method == 'PATCH') {
        list[i] = {...list[i], 'text': body()['text'], 'edited_at': DateTime.now().toUtc().toIso8601String()};
        return _json(list[i]);
      }
      if (method == 'DELETE') {
        list.removeAt(i);
        return http.Response('', 204);
      }
    }

    if (path.length == 2 && path[0] == 'places') {
      final summary = places.firstWhere((p) => p['id'] == path[1], orElse: () => {});
      if (summary.isEmpty) return _error(404, 'Place not found');
      return _json(placeJson(path[1], summary['name'] as String));
    }
    return _error(404, 'Not Found');
  });

  PlacesApi api() => PlacesApi(baseUrl: 'http://api.test', client: client);
}

class FakeOAuthLauncher implements OAuthLauncher {
  FakeOAuthLauncher({this.failure});

  static const String token = 'oauth-token';

  final LoginException? failure;
  final List<Uri> logins = [];

  @override
  Future<LoginResult> login(Uri loginUrl) async {
    logins.add(loginUrl);
    if (failure != null) throw failure!;
    return const LoginResult(token, 86400);
  }
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

  @override
  Future<bool> requestPermission() async => true;
}

/// Stands in for the gallery: "picks" [files] (or nothing when null = cancelled). No camera.
class FakeImagePicker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  List<XFile>? files;
  int picks = 0;

  static XFile photo(String name) => XFile.fromData(Uint8List.fromList([1, 2, 3]), name: name, path: name, mimeType: 'image/jpeg');

  @override
  bool supportsImageSource(ImageSource source) => source == ImageSource.gallery;

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async {
    picks++;
    final limit = options.limit;
    final chosen = files ?? const <XFile>[];
    return limit == null ? chosen : chosen.take(limit).toList();
  }

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    picks++;
    return files?.firstOrNull;
  }
}
