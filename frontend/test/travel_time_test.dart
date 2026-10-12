import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/services/travel_time_service.dart';

const _from = LatLon(50.0617, 19.9373);
const _to = LatLon(50.0647, 19.9450);

http.Response _route(num seconds) => http.Response(
  jsonEncode({
    'code': 'Ok',
    'routes': [
      {'duration': seconds},
    ],
  }),
  200,
);

void main() {
  test('czas dla każdego środka transportu', () async {
    final urls = <Uri>[];
    final service = TravelTimeService(
      client: MockClient((request) async {
        urls.add(request.url);
        return switch (request.url.pathSegments.first) {
          'routed-foot' => _route(600.4),
          'routed-bike' => _route(240),
          _ => _route(120),
        };
      }),
    );
    final times = await service.between(_from, _to);
    expect(times.durations, {
      TravelMode.walk: const Duration(seconds: 600),
      TravelMode.bike: const Duration(seconds: 240),
      TravelMode.car: const Duration(seconds: 120),
    });
    // OSRM takes lon,lat.
    expect(
      urls.first.path,
      '/routed-foot/route/v1/foot/19.937300,50.061700;19.945000,50.064700',
    );
  });

  test('wynik jest zapamiętywany', () async {
    var calls = 0;
    final service = TravelTimeService(
      client: MockClient((request) async {
        calls++;
        return _route(60);
      }),
    );
    await service.between(_from, _to);
    await service.between(_from, _to);
    expect(calls, TravelMode.values.length);
  });

  test('błędne odpowiedzi pomijają dany środek, nigdy nie rzucają', () async {
    final service = TravelTimeService(
      client: MockClient((request) async {
        return switch (request.url.pathSegments.first) {
          'routed-foot' => http.Response('not json', 200),
          'routed-bike' => http.Response(jsonEncode({'code': 'NoRoute'}), 200),
          _ => http.Response('', 500),
        };
      }),
    );
    final times = await service.between(_from, _to);
    expect(times.isEmpty, isTrue);
  });

  test('pusty wynik nie jest zapamiętywany (ponowna próba)', () async {
    var fail = true;
    final service = TravelTimeService(
      client: MockClient((request) async {
        if (fail) throw http.ClientException('offline');
        return _route(60);
      }),
    );
    expect((await service.between(_from, _to)).isEmpty, isTrue);
    fail = false;
    expect((await service.between(_from, _to)).isEmpty, isFalse);
  });
}
