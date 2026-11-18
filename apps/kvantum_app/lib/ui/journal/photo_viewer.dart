import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kvantum_core/kvantum_core.dart';

import 'photo_widgets.dart';

/// Opens the pictures of an entry full screen, at picture [initial].
Future<void> openPhotoViewer(
  BuildContext context,
  List<PhotoRef> photos, {
  int initial = 0,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => PhotoViewerPage(photos: photos, initial: initial),
  ),
);

/// The pictures of an entry, one to a page: swipe (or the arrow keys, or the
/// arrow buttons on a wide window) to the next, pinch or double-tap to zoom.
/// While a picture is zoomed in the swipe moves the picture, not the page.
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({super.key, required this.photos, this.initial = 0});

  final List<PhotoRef> photos;
  final int initial;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _pages;
  late int _index;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initial.clamp(0, widget.photos.length - 1);
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int to) {
    if (to < 0 || to >= widget.photos.length) return;
    _pages.animateToPage(
      to,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.photos.length;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _go(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _go(_index + 1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('photo-viewer'),
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Semantics(
              liveRegion: true,
              child: Text('${_index + 1} / $n', key: const Key('photo-count')),
            ),
          ),
          body: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                itemCount: n,
                onPageChanged: (i) => setState(() {
                  _index = i;
                  _zoomed = false;
                }),
                itemBuilder: (_, i) => _ZoomPage(
                  key: ValueKey(widget.photos[i].id),
                  photo: widget.photos[i],
                  label: 'Kép ${i + 1} / $n',
                  onZoomed: (z) {
                    if (z != _zoomed && i == _index) {
                      setState(() => _zoomed = z);
                    }
                  },
                ),
              ),
              if (wide && n > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: _Arrow(
                    key: const Key('photo-prev'),
                    icon: Icons.chevron_left,
                    tip: 'Előző kép',
                    onPressed: _index > 0 ? () => _go(_index - 1) : null,
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: _Arrow(
                    key: const Key('photo-next'),
                    icon: Icons.chevron_right,
                    tip: 'Következő kép',
                    onPressed: _index < n - 1 ? () => _go(_index + 1) : null,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    super.key,
    required this.icon,
    required this.tip,
    required this.onPressed,
  });
  final IconData icon;
  final String tip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: IconButton.filledTonal(
      tooltip: tip,
      onPressed: onPressed,
      icon: Icon(icon),
    ),
  );
}

/// One picture that can be zoomed.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({
    super.key,
    required this.photo,
    required this.label,
    required this.onZoomed,
  });
  final PhotoRef photo;
  final String label;
  final ValueChanged<bool> onZoomed;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> {
  final _controller = TransformationController();
  Offset _tapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  bool get _isZoomed => _controller.value.getMaxScaleOnAxis() > 1.01;

  void _changed() => widget.onZoomed(_isZoomed);

  /// A double tap zooms in on the spot, or back out when it is zoomed in.
  void _toggle() {
    if (_isZoomed) {
      _controller.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    _controller.value = Matrix4.identity()
      ..translateByDouble(
        -_tapAt.dx * (scale - 1),
        -_tapAt.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    image: true,
    label: widget.label,
    child: GestureDetector(
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _toggle,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1,
        maxScale: 6,
        child: SizedBox.expand(child: PhotoFull(photo: widget.photo)),
      ),
    ),
  );
}
