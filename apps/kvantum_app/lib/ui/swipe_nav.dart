import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// A swipe sideways needs this speed (logical pixels per second) …
const double swipeMinVelocity = 400;

/// … or this distance (logical pixels) to count as "go to the next / previous".
const double swipeMinDistance = 64;

/// Which way a finished swipe goes: +1 forward (the finger moved to the left,
/// as when a page is turned), -1 back, 0 when it was too short and too slow.
/// A fast flick counts even when it is short; a slow drag counts when it is
/// long enough; a drag that was started one way and ended the other does not
/// count by distance.
int swipeDirection({required double distance, required double velocity}) {
  if (velocity.abs() >= swipeMinVelocity) return velocity < 0 ? 1 : -1;
  if (distance.abs() >= swipeMinDistance) return distance < 0 ? 1 : -1;
  return 0;
}

/// Makes a horizontal swipe over [child] call [onStep] with +1 (next) or -1
/// (previous). Touch and pen only: with a mouse a drag over the calendar must
/// not move it by accident. Taps, and vertical scrolling inside [child], are
/// left alone.
class SwipeNav extends StatefulWidget {
  const SwipeNav({super.key, required this.onStep, required this.child});
  final void Function(int dir) onStep;
  final Widget child;

  @override
  State<SwipeNav> createState() => _SwipeNavState();
}

class _SwipeNavState extends State<SwipeNav> {
  double _dx = 0;

  void _end(DragEndDetails d) {
    final dir = swipeDirection(distance: _dx, velocity: d.primaryVelocity ?? 0);
    _dx = 0;
    if (dir != 0) widget.onStep(dir);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
    onHorizontalDragStart: (_) => _dx = 0,
    onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
    onHorizontalDragEnd: _end,
    onHorizontalDragCancel: () => _dx = 0,
    child: widget.child,
  );
}
