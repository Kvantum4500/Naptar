import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kvantum_app/ai/ai_settings.dart';
import 'package:kvantum_app/ai/place.dart';
import 'package:kvantum_app/ai/weather_service.dart';
import 'package:kvantum_core/kvantum_core.dart';

const forecastJson = {
  'daily': {
    'time': ['2026-11-10', '2026-11-11'],
    'temperature_2m_max': [9.4, 12.0],
    'temperature_2m_min': [3.1, 6.5],
    'precipitation_sum': [0.0, 4.2],
    'precipitation_probability_max': [10, 80],
    'wind_speed_10m_max': [14.2, 33.0],
    'weather_code': [3, 63],
  },
};

http.Response _json(Object body, [int code = 200]) => http.Response(
  jsonEncode(body),
  code,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  final bp = Place(name: 'Budapest', lat: 47.4979, lon: 19.0402);

  group('Place', () {
    test('coordinates are rounded to two decimals', () {
      expect(bp.lat, 47.5);
      expect(bp.lon, 19.04);
      expect(Place(name: '', lat: 1.23456, lon: -2.34567).label, '1.23, -2.35');
    });

    test('encode / decode round trip; garbage gives null', () {
      expect(Place.decode(bp.encode()), bp);
      expect(Place.decode(null), isNull);
      expect(Place.decode('nem json'), isNull);
      expect(Place.decode('{"lat": 99, "lon": 0}'), isNull);
      expect(Place.decode('{"lat": "x", "lon": 0}'), isNull);
    });
  });

  group('settings', () {
    test(
      'weather on by default; place and switch survive a save/load',
      () async {
        final mem = <String, String?>{};
        final store = AiSettingsStore(
          read: (k) async => mem[k],
          write: (k, v) async => v == null ? mem.remove(k) : mem[k] = v,
        );
        expect((await store.load()).weather, isTrue);
        expect((await store.load()).place, isNull);
        await store.save(AiSettings(weather: false, place: bp));
        final back = await store.load();
        expect(back.weather, isFalse);
        expect(back.place, bp);
        await store.save(back.copyWith(weather: true, clearPlace: true));
        expect((await store.load()).place, isNull);
        expect(mem.containsKey('ai.place'), isFalse);
      },
    );
  });

  group('WeatherService.forecast', () {
    test(
      'asks Open-Meteo with rounded coordinates only and parses the days',
      () async {
        late http.Request seen;
        final days = await WeatherService(
          MockClient((r) async {
            seen = r;
            return _json(forecastJson);
          }),
        ).forecast(bp, days: 5);
        expect(seen.url.host, 'api.open-meteo.com');
        expect(seen.url.path, '/v1/forecast');
        final q = seen.url.queryParameters;
        expect(q['latitude'], '47.50');
        expect(q['longitude'], '19.04');
        expect(q['forecast_days'], '5');
        expect(q['timezone'], 'Europe/Budapest');
        expect(q['daily'], contains('precipitation_probability_max'));
        // nothing but weather parameters leaves the app
        expect(q.keys.toSet(), {
          'latitude',
          'longitude',
          'daily',
          'timezone',
          'forecast_days',
        });
        expect(days!.length, 2);
        expect(days[1].precipProb, 80);
        expect(days[0].day, floating(2026, 11, 10));
      },
    );

    test('every failure is just null', () async {
      expect(
        await WeatherService(MockClient((_) async => _json({}, 500)))
            .forecast(bp),
        isNull,
      );
      expect(
        await WeatherService(MockClient((_) async => http.Response('x', 200)))
            .forecast(bp),
        isNull,
      );
      expect(
        await WeatherService(MockClient((_) async => _json({'daily': {}})))
            .forecast(bp),
        isNull,
      );
      expect(
        await WeatherService(
          MockClient((_) async => throw http.ClientException('offline')),
        ).forecast(bp),
        isNull,
      );
    });

    test(
      'a hanging service times out instead of blocking the assistant',
      () async {
        final svc = WeatherService(
          MockClient((_) => Completer<http.Response>().future),
          timeout: const Duration(milliseconds: 50),
        );
        expect(await svc.forecast(bp), isNull);
      },
    );

    test('the day count is kept within 1..16', () async {
      late http.Request seen;
      final svc = WeatherService(
        MockClient((r) async {
          seen = r;
          return _json(forecastJson);
        }),
      );
      await svc.forecast(bp, days: 40);
      expect(seen.url.queryParameters['forecast_days'], '16');
      await svc.forecast(bp, days: 0);
      expect(seen.url.queryParameters['forecast_days'], '1');
    });
  });

  group('the forecast is kept for a few hours', () {
    var clock = DateTime.utc(2026, 11, 10, 8); // 09:00 in Budapest
    var requests = 0;
    var status = 200;
    WeatherService svc({Completer<void>? gate}) => WeatherService(
      MockClient((r) async {
        requests++;
        await gate?.future;
        return _json(forecastJson, status);
      }),
      now: () => clock,
    );

    setUp(() {
      clock = DateTime.utc(2026, 11, 10, 8);
      requests = 0;
      status = 200;
    });

    test(
      'the same place, length and day within 3 hours: one request',
      () async {
        final s = svc();
        final a = await s.forecast(bp, days: 14);
        clock = clock.add(const Duration(hours: 2, minutes: 59));
        final b = await s.forecast(bp, days: 14);
        expect(requests, 1);
        expect(b, same(a));
      },
    );

    test('after 3 hours it is asked for again', () async {
      final s = svc();
      await s.forecast(bp, days: 14);
      clock = clock.add(const Duration(hours: 3, minutes: 1));
      await s.forecast(bp, days: 14);
      expect(requests, 2);
    });

    test('another place, or another length, is another forecast', () async {
      final s = svc();
      await s.forecast(bp, days: 14);
      await s.forecast(Place(name: 'Pécs', lat: 46.07, lon: 18.23), days: 14);
      await s.forecast(bp, days: 7);
      expect(requests, 3);
    });

    test(
      'a new local day is a new forecast, however fresh the old one is',
      () async {
        final s = svc();
        clock = DateTime.utc(2026, 11, 10, 22, 30); // 23:30 in Budapest
        await s.forecast(bp, days: 14);
        clock = DateTime.utc(2026, 11, 10, 23, 30); // 00:30 the next day
        await s.forecast(bp, days: 14);
        expect(requests, 2);
      },
    );

    test('a failure is not kept: the next ask tries again', () async {
      final s = svc();
      status = 500;
      expect(await s.forecast(bp, days: 14), isNull);
      status = 200;
      expect(await s.forecast(bp, days: 14), isNotNull);
      expect(await s.forecast(bp, days: 14), isNotNull);
      expect(requests, 2);
    });

    test('two asks at the same time make one request', () async {
      final gate = Completer<void>();
      final s = svc(gate: gate);
      final a = s.forecast(bp, days: 14);
      final b = s.forecast(bp, days: 14);
      gate.complete();
      expect((await a)!.length, 2);
      expect((await b)!.length, 2);
      expect(requests, 1);
    });
  });

  group('WeatherService.search', () {
    test('finds places with a readable name', () async {
      late http.Request seen;
      final r = await WeatherService(
        MockClient((req) async {
          seen = req;
          return _json({
            'results': [
              {
                'name': 'Győr',
                'admin1': 'Győr-Moson-Sopron',
                'country': 'Magyarország',
                'latitude': 47.68333,
                'longitude': 17.63512,
              },
              {'name': 'hibás'},
            ],
          });
        }),
      ).search('Győr');
      expect(seen.url.host, 'geocoding-api.open-meteo.com');
      expect(seen.url.queryParameters['name'], 'Győr');
      expect(r.single.name, 'Győr, Győr-Moson-Sopron, Magyarország');
      expect(r.single.lat, 47.68);
      expect(r.single.lon, 17.64);
    });

    test('a too short query makes no request; failures are empty', () async {
      var calls = 0;
      final svc = WeatherService(
        MockClient((_) async {
          calls++;
          return _json({}, 500);
        }),
      );
      expect(await svc.search(' g '), isEmpty);
      expect(calls, 0);
      expect(await svc.search('Győr'), isEmpty);
      expect(calls, 1);
    });
  });
}
