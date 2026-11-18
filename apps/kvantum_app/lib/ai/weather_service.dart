import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kvantum_core/kvantum_core.dart';

import '../diag/diag_log.dart';
import 'place.dart';

/// Forecast and place search from Open-Meteo (free, no key). Only rounded
/// coordinates are sent. Every failure (offline, timeout, odd answer) comes
/// back as null / empty, so the assistant simply works without weather.
class WeatherService {
  WeatherService(
    this._client, {
    Duration? timeout,
    Duration? cacheFor,
    DateTime Function()? now,
    this._log,
  }) : _timeout = timeout ?? const Duration(seconds: 8),
       _cacheFor = cacheFor ?? const Duration(hours: 3),
       _now = now ?? DateTime.now;
  final http.Client _client;
  final DiagLog? _log;
  final Duration _timeout;
  final Duration _cacheFor;
  final DateTime Function() _now;

  // A forecast changes slowly: the same place, length and local day get the
  // same answer for a few hours (every request, the "Mit küldünk?" preview
  // and the rule check ask for it). Only a real answer is kept; a failure is
  // tried again next time. One service lives as long as the app does.
  final _fresh = <String, ({DateTime at, List<DayWeather> days})>{};
  final _pending = <String, Future<List<DayWeather>?>>{};

  static const _forecastHost = 'api.open-meteo.com';
  static const _geoHost = 'geocoding-api.open-meteo.com';

  /// Daily forecast from today for [days] days (1–16), or null. A forecast
  /// fetched within the last [_cacheFor] (same place, length and local day) is
  /// reused, and two asks at the same time make one request.
  Future<List<DayWeather>?> forecast(
    Place place, {
    int days = 7,
    String timezone = 'Europe/Budapest',
  }) {
    final today = toWallClock(timezone, _now().toUtc());
    final key =
        '${place.lat.toStringAsFixed(2)}|${place.lon.toStringAsFixed(2)}|${days.clamp(1, 16)}|$timezone|${today.year}-${today.month}-${today.day}';
    final hit = _fresh[key];
    if (hit != null && _now().difference(hit.at) < _cacheFor) {
      return Future.value(hit.days);
    }
    return _pending[key] ??= _fetch(place, days, timezone)
        .then((list) {
          if (list != null) _fresh[key] = (at: _now(), days: list);
          return list;
        })
        .whenComplete(() {
          // (a block body: returning the removed future would make it wait for itself)
          _pending.remove(key);
        });
  }

  Future<List<DayWeather>?> _fetch(
    Place place,
    int days,
    String timezone,
  ) async {
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

  /// The answer as JSON, or null. Why there was none goes to the diagnostics
  /// log (the status, never the address: it holds the coordinates).
  Future<Object?> _get(Uri uri) async {
    try {
      final res = await _client.get(uri).timeout(_timeout);
      if (res.statusCode != 200) {
        _log?.info(
          'weather',
          'http',
          data: {'host': uri.host, 'status': res.statusCode},
        );
        return null;
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on TimeoutException {
      _log?.info('weather', 'timeout', data: {'host': uri.host});
      return null;
    } on FormatException catch (e, st) {
      _log?.error('weather', 'bad_answer', e, st, {'host': uri.host});
      return null;
    } catch (e, st) {
      // offline, TLS, DNS ...
      _log?.error('weather', 'failed', e, st, {'host': uri.host});
      return null;
    }
  }
}
