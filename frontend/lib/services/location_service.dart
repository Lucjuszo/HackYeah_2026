import 'package:geolocator/geolocator.dart';

import '../api/models.dart';

class LocationFailure implements Exception {
  const LocationFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Device position (browser geolocation on the web, Windows location service on desktop).
abstract class LocationService {
  Future<LatLon> currentLocation();
}

class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService();

  @override
  Future<LatLon> currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const LocationFailure('Usługi lokalizacji są wyłączone w systemie.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const LocationFailure(
          'Brak zgody na lokalizację. Możesz wpisać miasto lub adres.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LatLon(position.latitude, position.longitude);
    } on LocationFailure {
      rethrow;
    } on Object {
      throw const LocationFailure(
        'Nie udało się ustalić lokalizacji. Wpisz miasto lub adres.',
      );
    }
  }
}
