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

  /// Requests the platform permission without forcing a location lookup.
  /// Test and non-platform implementations can keep the default no-op behavior.
  Future<bool> requestPermission() async => true;
}

class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService();

  @override
  Future<bool> requestPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } on Object {
      return false;
    }
  }

  @override
  Future<LatLon> currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const LocationFailure(
          'Usługi lokalizacji są wyłączone w systemie.',
        );
      }
      if (!await requestPermission()) {
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
