/// Pure layout for the day/week time grid (no Flutter imports, easy to test).
class DayItem<T> {
  const DayItem(this.data, this.startMin, this.endMin);
  final T data;

  /// Minutes since the start of the day, clipped to 0..1440.
  final int startMin;
  final int endMin;
}

class Placed<T> {
  const Placed(this.item, this.column, this.columns);
  final DayItem<T> item;
  final int column; // 0-based
  final int columns; // columns in this overlap cluster
}

/// Side-by-side layout for overlapping events: events that overlap (directly
/// or through a chain) form a cluster; each gets a column, and the cluster
/// width is split between its columns.
List<Placed<T>> layoutDay<T>(List<DayItem<T>> items, {int minMinutes = 20}) {
  // Visual length: very short events still get a tappable block.
  int visEnd(DayItem<T> i) =>
      i.endMin - i.startMin < minMinutes ? i.startMin + minMinutes : i.endMin;

  final sorted = [...items]
    ..sort((a, b) {
      final c = a.startMin.compareTo(b.startMin);
      return c != 0 ? c : visEnd(b).compareTo(visEnd(a));
    });

  final out = <Placed<T>>[];
  var cluster = <DayItem<T>>[];
  var clusterEnd = -1;

  void flush() {
    if (cluster.isEmpty) return;
    final colEnds = <int>[];
    final cols = <int>[];
    for (final it in cluster) {
      var c = colEnds.indexWhere((end) => end <= it.startMin);
      if (c == -1) {
        colEnds.add(visEnd(it));
        c = colEnds.length - 1;
      } else {
        colEnds[c] = visEnd(it);
      }
      cols.add(c);
    }
    for (var i = 0; i < cluster.length; i++) {
      out.add(Placed(cluster[i], cols[i], colEnds.length));
    }
    cluster = [];
    clusterEnd = -1;
  }

  for (final it in sorted) {
    if (cluster.isNotEmpty && it.startMin >= clusterEnd) flush();
    cluster.add(it);
    final e = visEnd(it);
    if (e > clusterEnd) clusterEnd = e;
  }
  flush();
  return out;
}

/// Snaps [minutes] to the nearest multiple of [step] within one day.
int snapMinutes(double minutes, {int step = 15}) {
  final s = (minutes / step).round() * step;
  return s.clamp(0, 24 * 60 - step);
}
