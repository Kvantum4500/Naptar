import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart';

import 'place.dart';

/// Forecast and place search from Open-Meteo (free, no key). Only rounded
/// coordinates are sent. Every failure (offline, timeout, odd answer) comes
/// back as null / empty, so the assistant simply works without weather.
class WeatherService {
  WeatherService(this._client, {Duration? timeout})
    : _timeout = timeout ?? const Duration(seconds: 8);
  final http.Client _client;
  final Duration _timeout;

  static const _forecastHost = 'api.open-meteo.com';
  static const _geoHost = 'geocoding-api.open-meteo.com';

  /// Daily forecast from today for [days] days (1–16), or null.
  Future<List<DayWeather>?> forecast(
    Place place, {
    int days = 7,
    String timezone = 'Europe/Budapest',
  }) async {
    final uri = Uri.https(_forecastHost, '/v1/forecast', {
      'latitude': place.lat.toStringAsFixed(2),
      'longitude': place.lon.toStringAsFixed(2),
      'daily': [
        'weather_code',
        'temperature_2m_max',
        'temperature_2m_min',
        'precipitation_sum',
        'precipitation_probability_max',
        'wind_speed_10m_max',
      ].join(','),
      'timezone': timezone,
      'forecast_days': '${days.clamp(1, 16)}',
    });
    final json = await _get(uri);
    if (json == null) return null;
    final list = parseOpenMeteoDaily(json);
    return list.isEmpty ? null : list;
  }

  /// Up to five places matching [query] (for hand-typed cities).
  Future<List<Place>> search(String query, {String language = 'hu'}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final json = await _get(
      Uri.https(_geoHost, '/v1/search', {
        'name': q,
        'count': '5',
        'language': language,
        'format': 'json',
      }),
    );
    final results = json is Map ? json['results'] : null;
    if (results is! List) return const [];
    final out = <Place>[];
    for (final r in results) {
      if (r is! Map) continue;
      final lat = r['latitude'], lon = r['longitude'];
      if (lat is! num || lon is! num) continue;
      final name = [
        r['name'],
        r['admin1'],
        r['country'],
      ].where((e) => e is String && e.isNotEmpty).join(', ');
      out.add(Place(name: name, lat: lat.toDouble(), lon: lon.toDouble()));
    }
    return out;
  }

  Future<Object?> _get(Uri uri) async {
    try {
      final res = await _client.get(uri).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    } catch (_) {
      return null; // offline, TLS, DNS ...
    }
  }
}
