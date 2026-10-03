import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Backend address: `flutter run --dart-define=API_URL=http://localhost:8000`.
const String defaultApiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://localhost:8000',
);

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

enum PlaceSort {
  distance('distance', 'Najbliżej'),
  rating('rating', 'Najwyżej oceniane'),
  newest('newest', 'Najnowsze'),
  name('name', 'Alfabetycznie');

  const PlaceSort(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

/// Filters of GET /places/summary. Either [bounds] (visible map area) or [near] + [radiusM].
class PlacesQuery {
  const PlacesQuery({
    this.bounds,
    this.near,
    this.radiusM,
    this.text,
    this.wifi = false,
    this.powerOutlets = false,
    this.openNow = false,
    this.atmosphere,
    this.minRating,
    this.minPrice,
    this.maxPrice,
    this.sort,
  });

  final GeoBounds? bounds;
  final LatLon? near;
  final int? radiusM;
  final String? text;
  final bool wifi;
  final bool powerOutlets;
  final bool openNow;
  final Atmosphere? atmosphere;
  final double? minRating;
  final int? minPrice;
  final int? maxPrice;
  final PlaceSort? sort;

  Map<String, String> toQueryParameters() {
    String fixed(double value) => value.toStringAsFixed(5);
    final text = this.text?.trim();
    return {
      if (bounds case final b?)
        'bbox': [b.south, b.west, b.north, b.east].map(fixed).join(','),
      if (near case final n?) ...{'lat': fixed(n.lat), 'lon': fixed(n.lon)},
      if (near != null && radiusM != null) 'radius_m': '$radiusM',
      if (text != null && text.isNotEmpty) 'q': text,
      if (wifi) 'wifi': 'true',
      if (powerOutlets) 'power_outlets': 'true',
      if (openNow) 'open_now': 'true',
      if (atmosphere case final a?) 'atmosphere': a.apiValue,
      if (minRating case final r?) 'min_rating': '$r',
      if (minPrice case final p?) 'min_price': '$p',
      if (maxPrice case final p?) 'max_price': '$p',
      if (sort case final s?) 'sort': s.apiValue,
    };
  }
}

/// Read-only access to the public endpoints (no login needed).
class PlacesApi {
  PlacesApi({String baseUrl = defaultApiUrl, http.Client? client})
    : apiUrl = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
      _client = client ?? http.Client();

  final Uri apiUrl;
  final http.Client _client;

  static const Duration timeout = Duration(seconds: 15);

  Future<(Object?, http.Response)> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = apiUrl
        .resolve(path)
        .replace(queryParameters: query?.isEmpty ?? true ? null : query);
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on Exception {
      throw const ApiException(
        'Brak połączenia z serwerem. Sprawdź, czy backend działa.',
      );
    }
    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
    return (jsonDecode(utf8.decode(response.bodyBytes)), response);
  }

  static String _errorMessage(http.Response response) {
    if (response.statusCode == 404) return 'Nie znaleziono.';
    if (response.statusCode >= 500) {
      return 'Serwer ma chwilowy problem. Spróbuj za moment.';
    }
    try {
      final detail = (jsonDecode(utf8.decode(response.bodyBytes)) as Json)['detail'];
      if (detail is String) return detail;
    } on Object {
      // fall through
    }
    return 'Błąd ${response.statusCode}';
  }

  static int _total(http.Response response, int fallback) =>
      int.tryParse(response.headers['x-total-count'] ?? '') ?? fallback;

  Future<Page<PlaceSummary>> searchPlaces(
    PlacesQuery query, {
    int limit = 500,
  }) async {
    final (body, response) = await _get('places/summary', {
      ...query.toQueryParameters(),
      'limit': '$limit',
    });
    final items = [
      for (final json in body! as List)
        PlaceSummary.fromJson(json as Json, apiUrl: apiUrl),
    ];
    return Page(items, _total(response, items.length));
  }

  Future<Place> getPlace(String id) async {
    final (body, _) = await _get('places/${Uri.encodeComponent(id)}');
    return Place.fromJson(body! as Json, apiUrl: apiUrl);
  }

  Future<Page<Comment>> getComments(
    String placeId, {
    int limit = 20,
    int skip = 0,
  }) async {
    final (body, response) = await _get(
      'places/${Uri.encodeComponent(placeId)}/comments',
      {'limit': '$limit', 'skip': '$skip'},
    );
    final items = [
      for (final json in body! as List) Comment.fromJson(json as Json),
    ];
    return Page(items, _total(response, items.length));
  }

  Future<List<GeocodeResult>> geocode(String text) async {
    final (body, _) = await _get('geocode', {'q': text.trim(), 'limit': '6'});
    return [
      for (final json in body! as List) GeocodeResult.fromJson(json as Json),
    ];
  }
}
