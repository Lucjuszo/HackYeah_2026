import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/models.dart';

enum TravelMode {
  walk('routed-foot', 'foot', 'pieszo'),
  bike('routed-bike', 'bike', 'rowerem'),
  car('routed-car', 'driving', 'autem');

  const TravelMode(this.server, this.profile, this.label);

  final String server;
  final String profile;
  final String label;
}

/// Travel times by road from A to B; a mode is missing when it has no route.
class TravelTimes {
  const TravelTimes(this.durations);

  final Map<TravelMode, Duration> durations;

  bool get isEmpty => durations.isEmpty;
}

/// Route durations from the public OSRM servers of openstreetmap.de (they allow browser CORS).
class TravelTimeService {
  TravelTimeService({
    http.Client? client,
    this.baseUrl = 'https://routing.openstreetmap.de',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Map<String, Future<TravelTimes>> _cache = <String, Future<TravelTimes>>{};

  static const Duration timeout = Duration(seconds: 10);

  /// Never throws: modes that fail are left out.
  Future<TravelTimes> between(LatLon from, LatLon to) {
    String key(LatLon p) =>
        '${p.lat.toStringAsFixed(4)},${p.lon.toStringAsFixed(4)}';
    return _cache.putIfAbsent('${key(from)}>${key(to)}', () async {
      final results = await Future.wait(<Future<(TravelMode, Duration?)>>[
        for (final mode in TravelMode.values)
          _duration(mode, from, to).then((d) => (mode, d)),
      ]);
      final times = TravelTimes(<TravelMode, Duration>{
        for (final (mode, duration) in results) mode: ?duration,
      });
      if (times.isEmpty) _cache.remove('${key(from)}>${key(to)}'); // retry later
      return times;
    });
  }

  Future<Duration?> _duration(TravelMode mode, LatLon from, LatLon to) async {
    String point(LatLon p) =>
        '${p.lon.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}';
    final uri = Uri.parse(
      '$baseUrl/${mode.server}/route/v1/${mode.profile}/'
      '${point(from)};${point(to)}?overview=false',
    );
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
      if (body['code'] != 'Ok') return null;
      final routes = body['routes'] as List;
      if (routes.isEmpty) return null;
      final seconds = ((routes.first as Json)['duration'] as num).toDouble();
      return Duration(seconds: seconds.round());
    } on Object {
      return null;
    }
  }
}
