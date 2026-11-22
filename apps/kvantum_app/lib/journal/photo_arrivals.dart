import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The pictures that came in from another device while the program runs: how
/// often each file did ([photoArrivalsProvider] is a map from the name of the
/// file, `<id>.jpg`, to a count). A screen that shows a picture reads the count
/// of its file, so the place-holder gives way to the picture the moment it
/// arrives, and no other picture is touched.
class PhotoArrivals extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  /// The files that have just arrived.
  void arrived(Iterable<String> names) {
    if (names.isEmpty) return;
    final next = {...state};
    for (final n in names) {
      next[n] = (next[n] ?? 0) + 1;
    }
    state = next;
  }
}

final photoArrivalsProvider = NotifierProvider<PhotoArrivals, Map<String, int>>(
  PhotoArrivals.new,
);
