import 'package:flutter_test/flutter_test.dart';
import 'package:kvantum_app/ui/layout.dart';

DayItem<String> it(String n, int s, int e) => DayItem(n, s, e);
Map<String, Placed<String>> by(List<Placed<String>> p) => {
  for (final x in p) x.item.data: x,
};

void main() {
  test('non-overlapping events each use the full width', () {
    final p = by(layoutDay([it('a', 60, 120), it('b', 120, 180)]));
    expect(p['a']!.columns, 1);
    expect(p['b']!.columns, 1);
    expect(p['b']!.column, 0);
  });

  test('two overlapping events share the width', () {
    final p = by(layoutDay([it('a', 60, 150), it('b', 120, 180)]));
    expect(p['a']!.columns, 2);
    expect(p['b']!.columns, 2);
    expect({p['a']!.column, p['b']!.column}, {0, 1});
  });

  test('chain overlap forms one cluster; a freed column is reused', () {
    // a overlaps b, b overlaps c, a does not overlap c -> c reuses a's column.
    final p = by(
      layoutDay([it('a', 0, 60), it('b', 30, 90), it('c', 70, 120)]),
    );
    expect(p['a']!.columns, 2);
    expect(p['c']!.column, p['a']!.column);
    expect(p['b']!.column, isNot(p['a']!.column));
  });

  test('a later separate cluster is independent', () {
    final p = by(
      layoutDay([it('a', 0, 60), it('b', 30, 90), it('x', 300, 360)]),
    );
    expect(p['x']!.columns, 1);
  });

  test('very short events still occupy a minimum visual slot and collide', () {
    final p = by(layoutDay([it('a', 100, 100), it('b', 105, 130)]));
    expect(p['a']!.columns, 2);
  });

  test('identical times get distinct columns', () {
    final p = by(
      layoutDay([it('a', 60, 120), it('b', 60, 120), it('c', 60, 120)]),
    );
    expect({p['a']!.column, p['b']!.column, p['c']!.column}.length, 3);
    expect(p['a']!.columns, 3);
  });

  test('empty input', () => expect(layoutDay<String>([]), isEmpty));

  test('snapMinutes rounds to 15 and stays inside the day', () {
    expect(snapMinutes(7), 0);
    expect(snapMinutes(8), 15);
    expect(snapMinutes(547), 540);
    expect(snapMinutes(9999), 24 * 60 - 15);
    expect(snapMinutes(-30), 0);
  });
}
