import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kvantum_core/kvantum_core.dart';

import '../../journal/journal_providers.dart';
import '../../sync/photo_sync_switch.dart';

/// What a place-holder says where the picture is not on this device and is not
/// on its way (it was taken on another one, and the pictures do not travel
/// here: nobody is signed in, or the switch is off).
const photoElsewhereText = 'Ez a kép a másik eszközön van.';

/// What a place-holder says where the picture is not on this device yet, and
/// is on its way from Drive.
const photoComingText =
    'A kép a Drive-ról érkezik, a következő szinkronnál megjelenik.';

/// What a place-holder says where the picture is here, but this device cannot
/// show it (a kind it has no decoder for).
const photoUnreadableText = 'A kép ezen az eszközön nem jeleníthető meg.';

/// How wide (in pixels) a picture needs to be decoded to fill a square of
/// [side] pixels as a "cover": the shorter side of the picture is the side of
/// the square, so a wide picture needs a wider decode. Decoding at this size
/// (not the size of the file) is what keeps a list of many pictures light.
int thumbDecodeWidth(PhotoRef photo, double side) {
  final w = photo.width, h = photo.height;
  if (w <= 0 || h <= 0) return (side * 2).round();
  final wide = w >= h ? w / h : 1.0;
  return math.max(1, (side * wide).ceil());
}

/// A small square picture of an entry (or a place-holder). When it is given a
/// tap it is a button.
class PhotoThumb extends ConsumerWidget {
  const PhotoThumb({
    super.key,
    required this.photo,
    this.side = 72,
    this.onTap,
    this.label,
  });

  final PhotoRef photo;

  /// The side of the square, in logical pixels.
  final double side;
  final VoidCallback? onTap;

  /// What a screen reader says (the picture itself says nothing).
  final String? label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final pixels = side * MediaQuery.devicePixelRatioOf(context);
    final bytes = ref.watch(photoBytesProvider(photo.fileName));
    // (a picture that travels, when the pictures are on their way here)
    final coming = photo.syncable && ref.watch(photoSyncActiveProvider);
    final Widget content = bytes.when(
      data: (b) => b == null
          ? _Placeholder(
              side: side,
              icon: coming
                  ? Icons.cloud_download_outlined
                  : Icons.cloud_off_outlined,
              tip: coming ? photoComingText : photoElsewhereText,
            )
          : Image.memory(
              b,
              width: side,
              height: side,
              fit: BoxFit.cover,
              cacheWidth: thumbDecodeWidth(photo, pixels),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _Placeholder(
                side: side,
                icon: Icons.broken_image_outlined,
                tip: photoUnreadableText,
              ),
            ),
      loading: () => SizedBox(
        width: side,
        height: side,
        child: ColoredBox(color: scheme.surfaceContainerHighest),
      ),
      error: (_, _) => _Placeholder(
        side: side,
        icon: Icons.broken_image_outlined,
        tip: photoUnreadableText,
      ),
    );
    return Semantics(
      container: true,
      image: true,
      button: onTap != null,
      label: label ?? 'Kép',
      onTap: onTap,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: side,
          height: side,
          child: Stack(
            fit: StackFit.expand,
            children: [
              content,
              if (onTap != null)
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(onTap: onTap),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.side,
    required this.icon,
    required this.tip,
  });
  final double side;
  final IconData icon;
  final String tip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tip,
      child: ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Center(
          child: Icon(icon, size: side * 0.4, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// A picture as big as the room allows (the viewer), or the words that say why
/// there is none.
class PhotoFull extends ConsumerWidget {
  const PhotoFull({super.key, required this.photo});
  final PhotoRef photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(photoBytesProvider(photo.fileName));
    final coming = photo.syncable && ref.watch(photoSyncActiveProvider);
    return bytes.when(
      data: (b) => b == null
          ? (coming
                ? const _FullMessage(
                    photoComingText,
                    Icons.cloud_download_outlined,
                  )
                : const _FullMessage(
                    photoElsewhereText,
                    Icons.cloud_off_outlined,
                  ))
          : Image.memory(
              b,
              fit: BoxFit.contain,
              cacheWidth: 2400,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const _FullMessage(
                photoUnreadableText,
                Icons.broken_image_outlined,
              ),
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          const _FullMessage(photoUnreadableText, Icons.broken_image_outlined),
    );
  }
}

class _FullMessage extends StatelessWidget {
  const _FullMessage(this.text, this.icon);
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.white70),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    ),
  );
}
