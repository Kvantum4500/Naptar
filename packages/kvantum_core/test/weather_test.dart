import 'package:kvantum_core/kvantum_core.dart';
import 'package:test/test.dart';

const sample = {
  'daily': {
    'time': ['2026-11-10', '2026-11-11', 'hibás', '2026-11-12'],
    'temperature_2m_max': [9.4, 12.0, 1.0, null],
    'temperature_2m_min': [3.1, 6.5, 0.0, 2.0],
    'precipitation_sum': [0.0, 4.2, 0.0, 1.0],
    'precipitation_probability_max': [10, 80, 0, 30],
    'wind_speed_10m_max': [14.2, 33.0, 5.0, 20.0],
    'weather_code': [3, 63, 0, 1],
  },
};

void main() {
  setUpAll(ensureTimeZones);
  const rules = PlanRules();

  group('parseOpenMeteoDaily', () {
    test('reads days, skips unusable ones, keeps missing values null', () {
      final d = parseOpenMeteoDaily(sample);
      expect(d.length, 3);
      expect(d[0].day, floating(2026, 11, 10));
      expect(d[0].tMax, 9.4);
      expect(d[1].precipProb, 80);
      expect(d[1].code, 63);
      expect(d[2].tMax, isNull);
      expect(d[2].tMin, 2.0);
    });

    test('garbage never throws', () {
      expect(parseOpenMeteoDaily(null), isEmpty);
      expect(parseOpenMeteoDaily({'daily': 'x'}), isEmpty);
      expect(
        parseOpenMeteoDaily({
          'daily': {'time': 5},
        }),
        isEmpty,
      );
      expect(
        parseOpenMeteoDaily({
          'daily': {
            'time': ['2026-11-10'],
            'temperature_2m_max': ['meleg'],
          },
        }).single.tMax,
        isNull,
      );
    });
  });

  group('weatherForTool', () {
    test('a short Hungarian line per day; off means no data', () {
      final r = weatherForTool(parseOpenMeteoDaily(sample), place: 'Budapest');
      expect(r['helyszin'], 'Budapest');
      // one line per day, keyed by month-day
      final days = r['napok'] as Map;
      expect(days.keys.first, '11-10');
      expect(days['11-10'], contains('3–9 °C'));
      // a calm day is just the weather and the temperatures ...
      expect(days['11-10'], isNot(contains('csapadék')));
      expect(days['11-10'], isNot(contains('szél')));
      // ... rain and wind show up when they matter
      expect(days['11-11'], contains('csapadék 80%'));
      expect(days['11-11'], contains('4.2 mm'));
      expect(days['11-11'], contains('szél 33 km/h'));
      final off = weatherForTool(const [], place: 'x', enabled: false);
      expect(off['kikapcsolva'], isTrue);
      expect(off.containsKey('napok'), isFalse);
    });
  });

  group('outdoor sports and weather rules', () {
    test('outdoor sports are recognised by name', () {
      for (final t in [
        'Kajak 2 óra',
        'Biciklizés',
        'Falmászás',
        'Street Workout',
      ]) {
        expect(outdoorSport(t), isTrue, reason: t);
      }
      for (final t in ['Gym', 'Calisthenics 45 perc']) {
        expect(outdoorSport(t), isFalse, reason: t);
      }
    });

    ProposedBlock blk(String title, {bool outdoor = false}) => ProposedBlock(
      title: title,
      startUtc: resolveWallClock(rules.tzid, floating(2026, 11, 11, 17)),
      endUtc: resolveWallClock(rules.tzid, floating(2026, 11, 11, 18)),
      isWorkout: true,
      outdoor: outdoor,
    );

    List<String> codes(ProposedBlock b, DayWeather? w) => [
      for (final v in validateProposal(
        [b],
        existing: [],
        rules: rules,
        energyByDate: {floating(2026, 11, 11): 4},
        weatherByDate: {floating(2026, 11, 11): ?w},
      ))
        v.code,
    ];
    DayWeather w({
      double tMax = 15,
      double tMin = 8,
      int prob = 10,
      double mm = 0,
      double wind = 10,
    }) => DayWeather(
      day: floating(2026, 11, 11),
      tMax: tMax,
      tMin: tMin,
      precipProb: prob,
      precipMm: mm,
      windMax: wind,
    );

    test('good weather passes; rain, frost, wind, heat do not', () {
      expect(codes(blk('Street Workout'), w()), isEmpty);
      expect(codes(blk('Street Workout'), w(prob: 59)), isEmpty);
      expect(codes(blk('Street Workout'), w(prob: 60)), ['weather']);
      expect(codes(blk('Street Workout'), w(mm: 3)), ['weather']);
      expect(codes(blk('Street Workout'), w(tMin: -1)), ['weather']);
      expect(codes(blk('Street Workout'), w(tMax: 2)), ['weather']);
      expect(codes(blk('Street Workout'), w(wind: 40)), ['weather']);
      expect(codes(blk('Street Workout'), w(tMax: 34)), ['weather']);
    });

    test('kayaking is stricter (cold water, wind on the water)', () {
      expect(codes(blk('Kajak'), w(tMax: 9)), ['weather']);
      expect(codes(blk('Kajak'), w(tMax: 10, wind: 25)), ['weather']);
      expect(codes(blk('Kajak'), w(tMax: 18, wind: 12)), isEmpty);
      // the same day is fine for cycling
      expect(codes(blk('Kerékpározás'), w(tMax: 9, wind: 25)), isEmpty);
    });

    test('the model flag counts even when the name is not recognised', () {
      expect(codes(blk('Edzés a parkban', outdoor: true), w(prob: 90)), [
        'weather',
      ]);
      expect(codes(blk('Edzés a parkban'), w(prob: 90)), isEmpty);
    });

    test('indoor training and unknown forecasts are never blocked', () {
      expect(codes(blk('Gym'), w(prob: 100, tMin: -10)), isEmpty);
      expect(codes(blk('Kajak'), null), isEmpty);
    });

    test('parseProposal keeps the outdoor flag', () {
      final r = parseProposal({
        'proposals': [
          {
            'title': 'Edzés a parkban',
            'start': '2026-11-11T17:00:00',
            'end': '2026-11-11T18:00:00',
            'outdoor': true,
          },
        ],
      });
      expect(r.items.single.outdoor, isTrue);
      expect(r.items.single.toBlock().outdoor, isTrue);
    });
  });
}
