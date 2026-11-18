import 'package:geolocator/geolocator.dart';

import 'place.dart';

enum LocationFailure { serviceOff, denied, deniedForever, unavailable }

class LocationResult {
  const LocationResult.ok(Place this.place) : failure = null;
  const LocationResult.fail(LocationFailure this.failure) : place = null;
  final Place? place;
  final LocationFailure? failure;
}

/// Current position of the device, behind an interface so tests need no GPS.
abstract class LocationProvider {
  Future<LocationResult> current();
}

class GeolocatorLocationProvider implements LocationProvider {
  const GeolocatorLocationProvider();

  @override
  Future<LocationResult> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationResult.fail(LocationFailure.serviceOff);
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        return const LocationResult.fail(LocationFailure.deniedForever);
      }
      if (perm == LocationPermission.denied) {
        return const LocationResult.fail(LocationFailure.denied);
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low, // a city-level fix is enough
          timeLimit: Duration(seconds: 20),
        ),
      );
      return LocationResult.ok(
        Place(name: '', lat: p.latitude, lon: p.longitude),
      );
    } catch (_) {
      return const LocationResult.fail(LocationFailure.unavailable);
    }
  }
}
