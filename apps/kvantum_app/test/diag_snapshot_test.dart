import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/diag/diag_log.dart';
import 'package:kvantum_app/diag/diag_snapshot.dart';
import 'package:kvantum_app/diag/request_stats.dart';
import 'package:kvantum_app/sync/channel_status.dart';

const _title = 'Titkos edzés a Kiss Jánossal';

DiagSnapshot snap({
  List<DiagFailedItem>? failed,
  List<DiagEntry>? log,
  List<DiagWarning> warnings = const [],
  RequestTable? requests,
  int? build = 62,
  int? dbBytes = 3355443,
  Map<String, ChannelStatus>? channels,
}) => DiagSnapshot(
  at: DateTime(2026, 11, 12, 14, 30),
  build: build,
  platform: 'android',
  schema: 4,
  dbBytes: dbBytes,
  counts: const {'esemény': 120, 'feladat': 14, 'pénzügyi elem': 210},
  signedIn: true,
  pending: 2,
  parked: 1,
  nextAttempt: DateTime(2026, 11, 12, 14, 35),
  needsDecision: false,
  channels:
      channels ??
      {
        channelCalendar: ChannelStatus(
          lastTry: DateTime(2026, 11, 12, 14, 29),
          lastOk: DateTime(2026, 11, 12, 14, 20),
          code: 'parked',
          text: 'Naptár: 1 módosítást a Google nem fogadott el',
          pulled: 3,
          pushed: 1,
          failed: 1,
        ),
        channelDrive: ChannelStatus(
          lastTry: DateTime(2026, 11, 12, 14, 29),
          lastOk: DateTime(2026, 11, 12, 14, 29),
        ),
      },
  failed:
      failed ??
      const [
        DiagFailedItem(
          seq: 4,
          op: 'upsert',
          attempts: 5,
          parked: true,
          reason: 'a Google nem fogadta el (kód: 400, invalid)',
          title: _title,
        ),
      ],
  requests:
      requests ??
      {
        '2026-11-12': {
          'calendar': RequestCounts(calls: 40, ok: 37, throttled: 2, client: 1),
          'drive': RequestCounts(calls: 10, ok: 10),
        },
      },
  warnings: warnings,
  log:
      log ??
      [
        DiagEntry(
          time: DateTime.utc(2026, 11, 12, 13, 55, 1),
          area: 'sync',
          code: 'calendar.parked',
          data: const {'parked': 1},
          error: 'StateError: Bad state: x',
        ),
      ],
);

void main() {
  group('renderReport', () {
    test('has the sections, the numbers and the Hungarian sentences', () {
      final r = renderReport(
        snap(
          warnings: const [
            DiagWarning(
              'quota',
              'A Google ma 2 alkalommal korlátozta a kéréseket.',
            ),
          ],
        ),
      );
      for (final part in [
        'Kvantum Naptár – diagnosztikai jelentés',
        'Készült: 2026-11-12 14:30',
        '== Alkalmazás ==',
        'Verzió: build 62',
        'Platform: android',
        'Adatbázis: séma 4, 3,2 MB',
        'Elemek: esemény 120 · feladat 14 · pénzügyi elem 210',
        '== Szinkron ==',
        'Függő módosítás: 2 (feladva: 1)',
        'Következő próba: 2026-11-12 14:35',
        'Naptár: hiba (kód: parked)',
        'Drive (feladatok, check-inek, napló, étkezés, beállítások): rendben',
        'Pénzügy (levelek): még nem volt futás',
        'Képek (a napló képei, Drive): még nem volt futás',
        '1. módosítás, 5. próba, a Google nem fogadta el (kód: 400, invalid) [feladva]',
        '2026-11-12 Naptár: 40 hívás · 37 rendben · 1 elutasítva · 2 korlátozva',
        '- A Google ma 2 alkalommal korlátozta a kéréseket.',
        '== Hibanapló (utolsó 1 bejegyzés, UTC) ==',
        '11-12 13:55:01Z sync/calendar.parked parked=1 · StateError: Bad state: x',
      ]) {
        expect(r, contains(part), reason: part);
      }
    });

    test('tells what the pictures did, in a line of their own', () {
      final r = renderReport(
        snap(
          channels: {
            channelPhotos: ChannelStatus(
              lastTry: DateTime(2026, 11, 12, 14, 29),
              lastOk: DateTime(2026, 11, 12, 14, 10),
              code: 'quota',
              pulled: 2,
              pushed: 3,
              failed: 1,
            ),
          },
        ),
      );
      expect(
        r,
        contains(
          'Képek (a napló képei, Drive): hiba (kód: quota)'
          ' · utolsó próba 2026-11-12 14:29'
          ' · utolsó siker 2026-11-12 14:10'
          ' · 2 le, 3 fel, 1 nem ment át',
        ),
      );
    });

    test('never contains the title of an event', () {
      final r = renderReport(snap());
      expect(r, isNot(contains('Titkos')));
      expect(r, isNot(contains('Kiss János')));
    });

    test('says so when there is nothing to report', () {
      final r = renderReport(
        snap(
          failed: const [],
          log: const [],
          requests: {},
          build: null,
          dbBytes: null,
        ),
      );
      expect(r, contains('Verzió: ismeretlen'));
      expect(r, contains('Adatbázis: séma 4\n'));
      expect(r, contains('nincs'));
      expect(r, contains('még nincs adat'));
      expect(r, contains('üres'));
    });

    test('lists the days newest first and skips services without calls', () {
      final r = renderReport(
        snap(
          requests: {
            '2026-11-10': {'calendar': RequestCounts(calls: 3, ok: 3)},
            '2026-11-12': {
              'calendar': RequestCounts(calls: 1, ok: 1),
              'drive': RequestCounts(),
            },
          },
        ),
      );
      expect(r.indexOf('2026-11-12'), lessThan(r.indexOf('2026-11-10')));
      expect(r, isNot(contains('Drive: 0 hívás')));
    });
  });

  group('the small formatters', () {
    test('sizeText', () {
      expect(sizeText(512), '1 KB');
      expect(sizeText(480 * 1024), '480 KB');
      expect(sizeText(3355443), '3,2 MB');
    });

    test('entryLine: time, place, data and error on one line', () {
      final line = entryLine(
        DiagEntry(
          time: DateTime.utc(2026, 1, 2, 3, 4, 5),
          area: 'drive',
          code: 'push.failed',
          data: const {'kind': 'task', 'n': 2},
        ),
      );
      expect(line, '01-02 03:04:05Z drive/push.failed kind=task n=2');
    });
  });
}
