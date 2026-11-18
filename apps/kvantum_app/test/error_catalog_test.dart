import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DriftWrappedException;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kvantum_app/data/db_open.dart';
import 'package:kvantum_app/drive/drive_remote.dart';
import 'package:kvantum_app/google/google_auth_service.dart';
import 'package:kvantum_app/sync/api_errors.dart';
import 'package:kvantum_app/sync/error_catalog.dart';
import 'package:kvantum_app/sync/remote.dart';
import 'package:kvantum_core/kvantum_core.dart';
import 'package:sqlite3/common.dart' show SqliteException;

class _Weird {}

/// What must never reach the screen.
const _banned = [
  'Exception',
  'Instance of',
  'Error:',
  'null',
  r'$',
  'secrets.json',
  'flutter run',
  'dart-define',
  'SQL',
  'Stack',
];

/// The words of the message inside the exceptions below: none may be shown.
const _secret = 'titkos-szöveg-123';

void main() {
  void clean(ErrorInfo i) {
    expect(i.title, isNotEmpty);
    for (final w in _banned) {
      expect(
        i.text,
        isNot(contains(w)),
        reason: '${i.code}: "$w" in ${i.text}',
      );
    }
    expect(i.text, isNot(contains(_secret)), reason: i.code);
    expect(i.code, matches(RegExp(r'^[a-z0-9_.]+$')), reason: 'a stable code');
  }

  group('errorInfoFor: any error becomes a Hungarian line and a code', () {
    final cases = <String, Object>{
      'net.timeout': TimeoutException(_secret),
      'net.offline': const SocketException(_secret),
      'net.transient': TransientSyncError(_secret),
      'google.limit': TransientSyncError.throttled(_secret),
      'google.daily': TransientSyncError.throttled(_secret, dailyLimit: true),
      'google.rejected.400': ItemRejectedError(400, 'invalid', _secret),
      'google.conflict': ConflictException(),
      'google.calendar_gone': CalendarGoneError(),
      'fs.denied': FileSystemException(
        _secret,
        '/x',
        const OSError(_secret, 13),
      ),
      'fs.full': FileSystemException(_secret, '/x', const OSError(_secret, 28)),
      'fs.missing': FileSystemException(
        _secret,
        '/x',
        const OSError(_secret, 2),
      ),
      'fs.error': FileSystemException(_secret, '/x'),
      'db.sqlite.13': SqliteException(extendedResultCode: 13, message: _secret),
      'db.sqlite.1': SqliteException(extendedResultCode: 1, message: _secret),
      'db.error': DriftWrappedException(message: _secret),
      'format.newer': NewerFormatException(9),
      'data.format': const FormatException(_secret),
      'platform.missing': MissingPluginException(_secret),
      'platform.channel_error': PlatformException(
        code: 'channel-error',
        message: _secret,
      ),
      'app.bug.stateerror': StateError(_secret),
      'app.bug.argumenterror': ArgumentError(_secret),
      'unknown._weird': _Weird(),
    };

    cases.forEach((code, error) {
      test(code, () {
        final i = errorInfoFor(error);
        expect(i.code, code);
        clean(i);
      });
    });

    test('network exceptions of all kinds are "no connection"', () {
      for (final e in <Object>[
        http.ClientException(_secret),
        const HandshakeException(_secret),
        const HttpException(_secret),
        const TlsException(_secret),
      ]) {
        expect(errorInfoFor(e).code, 'net.offline', reason: '$e');
        clean(errorInfoFor(e));
      }
    });

    test('a Drive error reads like a Calendar error', () {
      expect(errorInfoFor(DriveTransientError(_secret)).code, 'net.transient');
      expect(
        errorInfoFor(DriveTransientError.throttled(_secret)).code,
        'google.limit',
      );
      expect(
        errorInfoFor(DriveTransientError.throttled(_secret, dailyLimit: true))
            .code,
        'google.daily',
      );
    });

    test(
      'a sign-in problem keeps its own Hungarian text and offers sign-in',
      () {
        final i = errorInfoFor(
          const SignInException('Nem sikerült a böngésző.'),
        );
        expect(i.title, 'Nem sikerült a böngésző.');
        expect(i.action, ErrorAction.signIn);
      },
    );

    test('a database error behind a drift wrapper is read through', () {
      final i = errorInfoFor(
        DriftWrappedException(
          message: _secret,
          cause: SqliteException(extendedResultCode: 13, message: _secret),
        ),
      );
      expect(i.code, 'db.sqlite.13');
    });

    test('a database that belongs to a newer version is a "newer" error', () {
      expect(errorInfoFor(const NewerDatabaseError(9, 4)).code, 'format.newer');
    });

    test('the platform code is made safe', () {
      final i = errorInfoFor(PlatformException(code: 'Nagy Hiba!!'));
      expect(i.code, 'platform.nagy_hiba_');
      expect(i.code, isNot(contains(' ')));
    });

    test('what asks for a look at the diagnostics says so', () {
      expect(errorInfoFor(StateError('x')).action, ErrorAction.diagnostics);
      expect(errorInfoFor(_Weird()).action, ErrorAction.diagnostics);
      expect(
        errorInfoFor(const SocketException('x')).action,
        ErrorAction.retry,
      );
    });
  });

  group('the sign-in lines', () {
    test('an unknown failure does not show the exception, only what to do', () {
      final t = signInFailedText(Exception(_secret));
      expect(t, startsWith('A bejelentkezés nem sikerült'));
      expect(t, contains('Diagnosztika'));
      expect(t, isNot(contains(_secret)));
      expect(t, isNot(contains('Exception')));
    });

    test('no connection says so', () {
      final t = signInFailedText(const SocketException(_secret));
      expect(t, contains('Nincs kapcsolat'));
      expect(t, isNot(contains(_secret)));
    });

    test('restoring the saved login has its own wording', () {
      expect(
        signInFailedText(StateError('x'), restore: true),
        startsWith('A mentett bejelentkezést nem sikerült visszaállítani'),
      );
    });

    test('a SignInException is shown as it is', () {
      expect(
        signInFailedText(const SignInException('Zárt a böngésző.')),
        'Zárt a böngésző.',
      );
    });
  });

  group('failed uploads are stored as codes, and read back in Hungarian', () {
    test('uploadErrorCode never contains the text of the error', () {
      expect(uploadErrorCode(ConflictException()), 'conflict');
      expect(
        uploadErrorCode(ItemRejectedError(403, 'forbidden', _secret)),
        'rejected:403:forbidden',
      );
      expect(
        uploadErrorCode(ItemRejectedError(400, null, _secret)),
        'rejected:400:unknown',
      );
      expect(
        uploadErrorCode(ItemRejectedError(400, 'Invalid Value!', _secret)),
        'rejected:400:invalid_value_',
      );
      expect(uploadErrorCode(TransientSyncError(_secret)), 'transient');
      expect(
        uploadErrorCode(TransientSyncError.throttled(_secret)),
        'transient:limit',
      );
      expect(
        uploadErrorCode(
          TransientSyncError.throttled(_secret, dailyLimit: true),
        ),
        'transient:daily',
      );
      expect(uploadErrorCode(StateError(_secret)), 'unexpected:stateerror');
      for (final e in <Object>[
        ConflictException(),
        ItemRejectedError(400, 'x', _secret),
        TransientSyncError(_secret),
        StateError(_secret),
      ]) {
        expect(uploadErrorCode(e), isNot(contains(_secret)));
      }
    });

    test('every code has a Hungarian line, and it is not the code', () {
      for (final code in [
        'conflict',
        'transient',
        'transient:limit',
        'transient:daily',
        'rejected:400:invalid',
        'rejected:403:unknown',
        'unexpected:stateerror',
      ]) {
        final t = outboxErrorText(code);
        expect(t, isNotEmpty);
        expect(t, isNot(contains('rejected:')), reason: code);
        expect(t, isNot(contains('unexpected:')), reason: code);
        expect(t, isNot(contains('transient')), reason: code);
      }
      expect(outboxErrorText('rejected:400:invalid'), contains('400'));
      expect(outboxErrorText('rejected:400:invalid'), contains('invalid'));
      expect(
        outboxErrorText('rejected:403:unknown'),
        isNot(contains('unknown')),
      );
    });

    test(
      'an old free-text value reads as an earlier error; nothing: not yet',
      () {
        expect(
          outboxErrorText('http 400 invalid: a title'),
          'korábbi hiba; újrapróbáláskor frissül',
        );
        expect(outboxErrorText(null), 'még nem sikerült feltölteni');
        expect(outboxErrorText(''), 'még nem sikerült feltölteni');
      },
    );
  });

  test('the "unexpected" line sends the user to the Diagnostics page', () {
    expect(unexpectedText('Naptár'), contains('Diagnosztika'));
    expect(unexpectedText('Naptár'), isNot(contains('Szinkron → Részletek')));
  });
}
