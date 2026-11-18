import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// The contrast between two colours as WCAG defines it: 1 (the same) to 21
/// (black on white). 4.5 is what text needs to be readable, 3 what an icon or
/// a bar needs. A translucent [a] is judged as it looks over [b].
double contrastRatio(Color a, Color b) {
  final over = Color.alphaBlend(a, b);
  final l1 = over.computeLuminance(), l2 = b.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

/// The colours that say "fine" and "watch out". A plain green or orange cannot
/// be read on the light surface (2.6 : 1 and 2.1 : 1); these two keep at least
/// 4.5 : 1 against every surface of the theme they belong to. "Over" is the
/// theme's own error colour.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.ok, required this.warn});

  final Color ok;
  final Color warn;

  static const light = StatusColors(
    ok: Color(0xFF1B5E20),
    warn: Color(0xFF8A4B00),
  );
  static const dark = StatusColors(
    ok: Color(0xFF81C784),
    warn: Color(0xFFFFB74D),
  );

  @override
  StatusColors copyWith({Color? ok, Color? warn}) =>
      StatusColors(ok: ok ?? this.ok, warn: warn ?? this.warn);

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      ok: Color.lerp(ok, other.ok, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
    );
  }
}

/// The status colours of the theme [context] is in (those of its brightness
/// when the theme carries none, as in a test with a plain theme).
StatusColors statusColorsOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<StatusColors>() ??
      (theme.brightness == Brightness.dark
          ? StatusColors.dark
          : StatusColors.light);
}

/// The theme of the app, light or dark.
ThemeData appTheme(Brightness brightness) => ThemeData(
  colorSchemeSeed: Colors.indigo,
  brightness: brightness,
  useMaterial3: true,
  extensions: [
    brightness == Brightness.dark ? StatusColors.dark : StatusColors.light,
  ],
);

/// Light, dark, or whatever the system says (the start). The choice is
/// remembered between runs.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'themeMode';

  @override
  ThemeMode build() {
    Future.microtask(_load);
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final saved = await ref.read(repoProvider).meta(_key);
    if (!ref.mounted) return;
    final mode = ThemeMode.values.where((e) => e.name == saved).firstOrNull;
    if (mode != null && mode != state) state = mode;
  }

  void set(ThemeMode mode) {
    state = mode;
    ref.read(repoProvider).setMeta(_key, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
