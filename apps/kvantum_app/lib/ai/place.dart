import 'dart:convert';

/// The place the weather is looked up for. Coordinates are kept at two
/// decimals (about 1 km): that is all a forecast needs and all that is ever
/// sent to the weather service.
class Place {
  Place({required this.name, required double lat, required double lon})
    : lat = _round(lat),
      lon = _round(lon);

  final String name;
  final double lat;
  final double lon;

  static double _round(double v) => (v * 100).round() / 100;

  String get label => name.isEmpty
      ? '${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)}'
      : name;

  String encode() => jsonEncode({'name': name, 'lat': lat, 'lon': lon});

  static Place? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s);
      if (m is! Map) return null;
      final lat = m['lat'], lon = m['lon'];
      if (lat is! num || lon is! num) return null;
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
      return Place(
        name: '${m['name'] ?? ''}',
        lat: lat.toDouble(),
        lon: lon.toDouble(),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Place &&
      other.name == name &&
      other.lat == lat &&
      other.lon == lon;

  @override
  int get hashCode => Object.hash(name, lat, lon);
}
