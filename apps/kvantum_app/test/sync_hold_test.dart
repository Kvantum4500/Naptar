import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/sync/sync_hold.dart';

void main() {
  test('nothing is held to begin with', () {
    final h = SyncHold();
    expect(h.isEmpty, isTrue);
    expect(h.isHeld('a'), isFalse);
  });

  test('a held id is held until its token is released', () {
    final h = SyncHold();
    final t = h.acquire(['a', 'b']);
    expect(h.isHeld('a'), isTrue);
    expect(h.isHeld('b'), isTrue);
    expect(h.isHeld('c'), isFalse);
    t.release();
    expect(h.isHeld('a'), isFalse);
    expect(h.isHeld('b'), isFalse);
    expect(h.isEmpty, isTrue);
  });

  test('releasing twice is harmless and does not free another hold', () {
    final h = SyncHold();
    final first = h.acquire(['a']);
    final second = h.acquire(['a']);
    first.release();
    first.release(); // again: must not count twice
    expect(first.released, isTrue);
    expect(h.isHeld('a'), isTrue, reason: 'the second hold is still there');
    second.release();
    expect(h.isHeld('a'), isFalse);
  });

  test('holds on the same id add up', () {
    final h = SyncHold();
    final a = h.acquire(['x']);
    final b = h.acquire(['x', 'y']);
    a.release();
    expect(h.isHeld('x'), isTrue);
    expect(h.isHeld('y'), isTrue);
    b.release();
    expect(h.isEmpty, isTrue);
  });

  test('the hold on a series covers its exceptions', () {
    final h = SyncHold();
    final t = h.acquire(['master']);
    expect(h.isHeld('exception-1', seriesId: 'master'), isTrue);
    expect(h.isHeld('exception-1', seriesId: 'other'), isFalse);
    expect(h.isHeld('exception-1'), isFalse);
    t.release();
    expect(h.isHeld('exception-1', seriesId: 'master'), isFalse);
  });

  test('duplicate ids in one acquire count once', () {
    final h = SyncHold();
    final t = h.acquire(['a', 'a']);
    t.release();
    expect(h.isHeld('a'), isFalse);
  });
}
