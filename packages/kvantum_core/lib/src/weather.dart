import 'time.dart';

/// One day of the forecast (Open-Meteo daily values, km/h and °C).
class DayWeather {
  const DayWeather({
    required this.day,
    this.tMax,
    this.tMin,
    this.precipMm,
    this.precipProb,
    this.windMax,
    this.code,
  });

  /// Floating date (y/m/d, UTC-flagged).
  final DateTime day;
  final double? tMax;
  final double? tMin;
  final double? precipMm;
  final int? precipProb;
  final double? windMax;

  /// WMO weather code.
  final int? code;
}

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

DateTime? _ymd(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v);
  if (m == null) return null;
  final mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return floating(int.parse(m[1]!), mo, d);
}

/// Reads the `daily` block of an Open-Meteo forecast. Never throws: days
/// without a usable date are skipped, missing values stay null.
List<DayWeather> parseOpenMeteoDaily(Object? json) {
  final daily = json is Map ? json['daily'] : null;
  if (daily is! Map) return const [];
  final times = daily['time'];
  if (times is! List) return const [];
  List<Object?> col(String k) {
    final v = daily[k];
    return v is List ? v : const [];
  }

  final tMax = col('temperature_2m_max');
  final tMin = col('temperature_2m_min');
  final mm = col('precipitation_sum');
  final prob = col('precipitation_probability_max');
  final wind = col('wind_speed_10m_max');
  final code = col('weather_code');
  Object? at(List<Object?> l, int i) => i < l.length ? l[i] : null;

  final out = <DayWeather>[];
  for (var i = 0; i < times.length; i++) {
    final day = _ymd(times[i]);
    if (day == null) continue;
    final p = _num(at(prob, i));
    final c = _num(at(code, i));
    out.add(
      DayWeather(
        day: day,
        tMax: _num(at(tMax, i)),
        tMin: _num(at(tMin, i)),
        precipMm: _num(at(mm, i)),
        precipProb: p?.round(),
        windMax: _num(at(wind, i)),
        code: c?.round(),
      ),
    );
  }
  return out;
}

/// Short Hungarian description of a WMO code (only the coarse classes).
String weatherWord(int? code) {
  if (code == null) return '';
  if (code == 0) return 'derült';
  if (code <= 3) return 'felhős';
  if (code == 45 || code == 48) return 'köd';
  if (code >= 51 && code <= 57) return 'szitálás';
  if (code >= 61 && code <= 67) return 'eső';
  if (code >= 71 && code <= 77) return 'hó';
  if (code >= 80 && code <= 82) return 'zápor';
  if (code == 85 || code == 86) return 'hózápor';
  if (code >= 95) return 'zivatar';
  return '';
}

String _deg(double? v) => v == null ? '?' : v.round().toString();

String _line(DayWeather w) {
  final parts = <String>[
    weatherWord(w.code),
    if (w.tMin != null || w.tMax != null) '${_deg(w.tMin)}–${_deg(w.tMax)} °C',
    if (w.precipProb != null) 'csapadék ${w.precipProb}%',
    if (w.precipMm != null && w.precipMm! >= 0.5)
      '${w.precipMm!.toStringAsFixed(w.precipMm! < 10 ? 1 : 0)} mm',
    if (w.windMax != null) 'szél ${w.windMax!.round()} km/h',
  ].where((s) => s.isNotEmpty).toList();
  return parts.join(', ');
}

/// Data block for the assistant. [place] is only the place's name.
Map<String, Object?> weatherForTool(
  List<DayWeather> days, {
  required String place,
  bool enabled = true,
}) {
  if (!enabled) {
    return {
      'kikapcsolva': true,
      'uzenet': 'A felhasználó nem engedi az időjárás használatát.',
    };
  }
  String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return {
    'adat_tipus': 'idojaras',
    'helyszin': place,
    'napok': [
      for (final w in days) {'nap': ymd(w.day), 'elorejelzes': _line(w)},
    ],
  };
}

/// Sports that are done outside and depend on the weather.
bool outdoorSport(String title) => RegExp(
  r'kajak|evez|bicikl|kerékpár|mászás|street|túra|szabadtér|kirándul',
  caseSensitive: false,
).hasMatch(title);

bool _water(String title) =>
    RegExp(r'kajak|evez', caseSensitive: false).hasMatch(title);

/// Why this day's weather rules an outdoor activity out, or null when it is
/// fine. Water sports are stricter (cold water, wind on the water).
String? weatherProblem(DayWeather w, {required String title}) {
  final water = _water(title);
  final why = <String>[];
  if ((w.precipProb ?? 0) >= 60) why.add('csapadék ${w.precipProb}%');
  if ((w.precipMm ?? 0) >= 3) {
    why.add('${w.precipMm!.toStringAsFixed(1)} mm csapadék');
  }
  if (w.tMin != null && w.tMin! < 0) why.add('fagyos (${_deg(w.tMin)} °C)');
  if (w.tMax != null && w.tMax! < (water ? 10 : 3)) {
    why.add('túl hideg (max ${_deg(w.tMax)} °C)');
  }
  if (w.tMax != null && w.tMax! > 33) {
    why.add('túl meleg (max ${_deg(w.tMax)} °C)');
  }
  if (w.windMax != null && w.windMax! >= (water ? 25 : 40)) {
    why.add('erős szél (${w.windMax!.round()} km/h)');
  }
  return why.isEmpty ? null : why.join(', ');
}
