import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/notify/budget_notify.dart';

import 'support/fake_toasts.dart';

void main() {
  group('the id of a notification', () {
    test('the same news in the same month always has the same id', () {
      // (fixed values: a changed hash would leave the old notifications on the
      // device beside the new ones)
      expect(budgetNotificationId('2026-11', 'cat-food'), 1714578439);
      expect(budgetNotificationId('2026-11', 'cat-fun'), 1765540220);
      expect(budgetNotificationId('2026-12', 'cat-food'), 1781398328);
      expect(budgetNotificationId('2026-11', '*'), 1745316794);
    });

    test('another month or another category is another notification', () {
      final ids = {
        for (final m in ['2026-10', '2026-11', '2026-12'])
          for (final k in ['cat-food', 'cat-fun', 'cat-home', '*'])
            budgetNotificationId(m, k),
      };
      expect(ids, hasLength(12));
    });

    test('the month and the key do not run into each other', () {
      expect(
        budgetNotificationId('2026-1', '1|x') ==
            budgetNotificationId('2026-11', 'x'),
        isFalse,
      );
    });

    test('always between the morning summaries and the test notification', () {
      for (var i = 0; i < 3000; i++) {
        final id = budgetNotificationId('2026-${i % 12 + 1}', 'category-$i');
        expect(id, greaterThanOrEqualTo(1700000000));
        expect(id, lessThan(1800000000));
      }
      expect(budgetNotificationIdBase, 1700000000);
      expect(budgetNotificationIdRange, 100000000);
    });
  });

  group('Android', () {
    test('its own channel, so that it can be silenced on its own', () {
      final d = AndroidBudgetNotifier.detailsFor('Egy sor').android!;
      expect(d.channelId, 'budget');
      expect(d.channelName, 'Költségkeret');
      expect(AndroidBudgetNotifier.channelId, 'budget');
      expect(AndroidBudgetNotifier.channelName, 'Költségkeret');
      expect(d.importance, Importance.defaultImportance);
      expect(d.channelDescription, isNotEmpty);
    });

    test('a list of several lines opens up, a short text stays as it is', () {
      expect(
        AndroidBudgetNotifier.detailsFor('Egy sor').android!.styleInformation,
        isNull,
      );
      final many = AndroidBudgetNotifier.detailsFor('Étel: 85%\nLakás: 90%');
      final style = many.android!.styleInformation;
      expect(style, isA<BigTextStyleInformation>());
      expect(
        (style! as BigTextStyleInformation).bigText,
        'Étel: 85%\nLakás: 90%',
      );
    });
  });

  group('Windows', () {
    test('it can show, and asks Windows only to start', () async {
      final toasts = FakeToasts();
      final n = WindowsBudgetNotifier(toasts);
      expect(n.supported, isTrue);
      expect(await n.ensurePermission(), isTrue);
      expect(toasts.inits, 1);

      await n.show(id: 1714578439, title: 'Cím', body: 'Szöveg');
      expect(toasts.shownNow, [(id: 1714578439, title: 'Cím', body: 'Szöveg')]);
      // nothing was scheduled: this is not a reminder
      expect(toasts.handedOver, isEmpty);
      expect(toasts.os, isEmpty);
    });

    test(
      'when Windows cannot be started it says so and shows nothing',
      () async {
        final toasts = FakeToasts()..initOk = false;
        final n = WindowsBudgetNotifier(toasts);
        expect(await n.ensurePermission(), isFalse);
        await expectLater(
          n.show(id: 1, title: 't', body: 'b'),
          throwsA(isA<StateError>()),
        );
        expect(toasts.shownNow, isEmpty);
      },
    );

    test('a refusal of Windows is not hidden', () async {
      final toasts = FakeToasts()..failShow = true;
      await expectLater(
        WindowsBudgetNotifier(toasts).show(id: 1, title: 't', body: 'b'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('anywhere else there is nothing to show with', () async {
    final n = NoopBudgetNotifier();
    expect(n.supported, isFalse);
    expect(await n.ensurePermission(), isFalse);
    await n.show(id: 1, title: 't', body: 'b'); // (and no complaint)
  });

  group('the notifier of a platform', () {
    final toasts = FakeToasts();
    BudgetNotifier pick({bool android = false, bool windows = false}) =>
        budgetNotifierFor(
          android: android,
          windows: windows,
          toastBackend: () => toasts,
        );

    test('Android has its own, Windows the toasts, the rest none', () {
      expect(pick(android: true), isA<AndroidBudgetNotifier>());
      expect(pick(windows: true), isA<WindowsBudgetNotifier>());
      expect(pick(), isA<NoopBudgetNotifier>());
    });

    test('the Windows one uses the connection it is given', () async {
      final n = pick(windows: true);
      await n.show(id: 7, title: 'a', body: 'b');
      expect(toasts.shownNow.single.id, 7);
    });
  });
}
