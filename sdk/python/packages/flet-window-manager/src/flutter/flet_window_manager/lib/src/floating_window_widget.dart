import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A single floating window with title bar, resize handles, and window buttons.
///
/// Position changes during drag/resize use a ValueNotifier so only the
/// lightweight Positioned wrapper rebuilds — the window chrome and child
/// content are wrapped in RepaintBoundary and never rebuild during drag.
class FloatingWindowWidget extends StatefulWidget {
  final Control control;

  const FloatingWindowWidget({
    super.key,
    required this.control,
  });

  @override
  State<FloatingWindowWidget> createState() => _FloatingWindowWidgetState();
}

class _Rect {
  double left, top, width, height;
  _Rect(this.left, this.top, this.width, this.height);
}

class _FloatingWindowWidgetState extends State<FloatingWindowWidget> {
  // Position notifier — triggers ONLY the Positioned wrapper, not the chrome
  final _rect = ValueNotifier<_Rect>(_Rect(100, 100, 800, 400));

  // Saved rect for maximize/restore
  double _savedLeft = 0;
  double _savedTop = 0;
  double _savedWidth = 0;
  double _savedHeight = 0;

  bool _maximized = false;
  bool _visible = true;
  bool _initialized = false;

  // Cached child widgets and chrome — only rebuilt on control change
  List<Widget> _cachedChildren = const [];
  Widget? _cachedChrome;
  String _lastTitle = '';
  String _lastTitleBarColor = '';
  String _lastChromeColor = '';

  // Current viewport bounds — updated on every LayoutBuilder pass
  double _vpWidth = 0;
  double _vpHeight = 0;

  static const double _titleBarHeight = 32.0;
  static const double _resizeHandleSize = 6.0;
  static const double _minWidth = 200.0;
  static const double _minHeight = 100.0;
  static const _borderColor = Color(0xFF0891B3);

  @override
  void initState() {
    super.initState();
    _syncFromControl();
  }

  @override
  void dispose() {
    _rect.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FloatingWindowWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFromControl();
  }

  void _syncFromControl() {
    final c = widget.control;
    _visible = c.getBool("win_visible", true)!;

    if (!_initialized) {
      final l = c.getDouble("win_left", 100)!;
      final t = c.getDouble("win_top", 100)!;
      final w = c.getDouble("win_width", 800)!;
      final h = c.getDouble("win_height", 400)!;
      _rect.value = _Rect(l, t, w, h);
      _maximized = c.getBool("maximized", false)!;
      _initialized = true;
    }

    _cachedChildren = widget.control.buildWidgets("controls");

    // Invalidate chrome cache when properties change
    final title = c.getString("title") ?? "";
    final tbc = c.getString("title_bar_color") ?? "";
    final cc = c.getString("chrome_color") ?? "";
    if (title != _lastTitle || tbc != _lastTitleBarColor || cc != _lastChromeColor) {
      _lastTitle = title;
      _lastTitleBarColor = tbc;
      _lastChromeColor = cc;
      _cachedChrome = null; // force rebuild
    }
  }

  Color _parseColor(String? hex, Color fallback) {
    if (hex == null || hex.isEmpty) return fallback;
    try {
      var h = hex.replaceFirst('#', '');
      if (h.length == 6) h = 'FF$h';
      return Color(int.parse(h, radix: 16));
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    print('[wmdiag] FloatingWindow.build t=${DateTime.now().millisecondsSinceEpoch} '
        'visible=$_visible chromeCached=${_cachedChrome != null}');
    return LayoutControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Store viewport bounds so drag handlers always have fresh values
          _vpWidth = constraints.maxWidth;
          _vpHeight = constraints.maxHeight;
          final effectiveOpacity = _visible ? 1.0 : 0.0;

          // Build chrome once, cache it. RepaintBoundary isolates it from
          // position changes so it never repaints during drag.
          _cachedChrome ??= RepaintBoundary(
            child: _buildWindowChrome(
              _lastTitle,
              _parseColor(_lastTitleBarColor, const Color(0xFF1E1E2E)),
              _parseColor(_lastChromeColor, const Color(0xFF26252D)),
            ),
          );

          return IgnorePointer(
            ignoring: !_visible,
            child: SizedBox.expand(
              // ValueListenableBuilder rebuilds ONLY the positioning wrapper
              // on drag/resize — the chrome inside RepaintBoundary is untouched.
              child: ValueListenableBuilder<_Rect>(
                valueListenable: _rect,
                builder: (context, rect, _) {
                  double eL, eT, eW, eH;
                  if (_maximized) {
                    eL = 0; eT = 0; eW = _vpWidth; eH = _vpHeight;
                  } else {
                    eL = rect.left; eT = rect.top;
                    eW = rect.width.clamp(_minWidth, _vpWidth);
                    eH = rect.height.clamp(_minHeight, _vpHeight);
                  }

                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: eL,
                        top: eT,
                        child: Opacity(
                          opacity: effectiveOpacity,
                          child: SizedBox(
                            width: eW,
                            height: eH,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Chrome (cached + RepaintBoundary)
                                Positioned.fill(child: _cachedChrome!),
                                // Resize handles
                                if (!_maximized) ..._buildResizeHandles(eW, eH),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWindowChrome(
    String title,
    Color titleBarColor,
    Color chromeColor,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: chromeColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderColor, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Title bar
          _buildTitleBar(title, titleBarColor),
          // Content area
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(7),
                bottomRight: Radius.circular(7),
              ),
              child: _cachedChildren.isNotEmpty
                  ? _cachedChildren.first
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleBar(String title, Color titleBarColor) {
    return GestureDetector(
      onPanUpdate: _maximized
          ? null
          : (details) {
              final r = _rect.value;
              // Allow dragging down until only the title bar is visible
              _rect.value = _Rect(
                (r.left + details.delta.dx).clamp(-r.width + 100, _vpWidth - 100),
                (r.top + details.delta.dy).clamp(0.0, _vpHeight - _titleBarHeight),
                r.width,
                r.height,
              );
            },
      onPanEnd: _maximized ? null : (_) => _sendPositionToBackend(),
      onDoubleTap: _toggleMaximize,
      child: Container(
        height: _titleBarHeight,
        decoration: BoxDecoration(
          color: titleBarColor,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(7),
            topRight: Radius.circular(7),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Color(0xFFCCCCCC),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _windowButton(
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              tooltip: _maximized ? 'Restore' : 'Maximize',
              onPressed: _toggleMaximize,
            ),
            _windowButton(
              icon: Icons.close,
              tooltip: 'Close',
              onPressed: _onClose,
              hoverColor: const Color(0xFFE81123),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _windowButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color hoverColor = const Color(0x33FFFFFF),
  }) {
    return _HoverIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      hoverColor: hoverColor,
      size: _titleBarHeight - 4,
    );
  }

  List<Widget> _buildResizeHandles(double windowWidth, double windowHeight) {
    return [
      _resizeHandle(cursor: SystemMouseCursors.resizeUp,
        left: _resizeHandleSize, top: 0,
        width: windowWidth - _resizeHandleSize * 2, height: _resizeHandleSize,
        onDrag: (dx, dy) => _resizeTop(dy)),
      _resizeHandle(cursor: SystemMouseCursors.resizeDown,
        left: _resizeHandleSize, top: windowHeight - _resizeHandleSize,
        width: windowWidth - _resizeHandleSize * 2, height: _resizeHandleSize,
        onDrag: (dx, dy) => _resizeBottom(dy)),
      _resizeHandle(cursor: SystemMouseCursors.resizeLeft,
        left: 0, top: _resizeHandleSize,
        width: _resizeHandleSize, height: windowHeight - _resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeLeft(dx)),
      _resizeHandle(cursor: SystemMouseCursors.resizeRight,
        left: windowWidth - _resizeHandleSize, top: _resizeHandleSize,
        width: _resizeHandleSize, height: windowHeight - _resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeRight(dx)),
      _resizeHandle(cursor: SystemMouseCursors.resizeUpLeft,
        left: 0, top: 0,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeLeft(dx); _resizeTop(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeUpRight,
        left: windowWidth - _resizeHandleSize, top: 0,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeRight(dx); _resizeTop(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeDownLeft,
        left: 0, top: windowHeight - _resizeHandleSize,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeLeft(dx); _resizeBottom(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeDownRight,
        left: windowWidth - _resizeHandleSize, top: windowHeight - _resizeHandleSize,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeRight(dx); _resizeBottom(dy); }),
    ];
  }

  Widget _resizeHandle({
    required SystemMouseCursor cursor,
    required double left, required double top,
    required double width, required double height,
    required void Function(double dx, double dy) onDrag,
  }) {
    return Positioned(
      left: left, top: top,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          onPanUpdate: (details) => onDrag(details.delta.dx, details.delta.dy),
          onPanEnd: (_) => _sendPositionToBackend(),
          child: Container(width: width, height: height, color: Colors.transparent),
        ),
      ),
    );
  }

  void _resizeLeft(double dx) {
    final r = _rect.value;
    final nw = r.width - dx;
    final nl = r.left + dx;
    if (nw >= _minWidth && nl >= -50) {
      _rect.value = _Rect(nl, r.top, nw, r.height);
    }
  }

  void _resizeRight(double dx) {
    final r = _rect.value;
    final nw = r.width + dx;
    if (nw >= _minWidth && r.left + nw <= _vpWidth + 50) {
      _rect.value = _Rect(r.left, r.top, nw, r.height);
    }
  }

  void _resizeTop(double dy) {
    final r = _rect.value;
    final nh = r.height - dy;
    final nt = r.top + dy;
    if (nh >= _minHeight && nt >= 0) {
      _rect.value = _Rect(r.left, nt, r.width, nh);
    }
  }

  void _resizeBottom(double dy) {
    final r = _rect.value;
    final nh = r.height + dy;
    if (nh >= _minHeight && r.top + nh <= _vpHeight + 50) {
      _rect.value = _Rect(r.left, r.top, r.width, nh);
    }
  }

  void _toggleMaximize() {
    if (_maximized) {
      _rect.value = _Rect(_savedLeft, _savedTop, _savedWidth, _savedHeight);
      _maximized = false;
    } else {
      final r = _rect.value;
      _savedLeft = r.left; _savedTop = r.top;
      _savedWidth = r.width; _savedHeight = r.height;
      _maximized = true;
    }
    // Force chrome rebuild for button icon change
    _cachedChrome = null;
    setState(() {});
    FletBackend.of(context).updateControl(widget.control.id, {
      'maximized': _maximized.toString(),
      'win_left': _rect.value.left.toString(),
      'win_top': _rect.value.top.toString(),
      'win_width': _rect.value.width.toString(),
      'win_height': _rect.value.height.toString(),
    });
    FletBackend.of(context).triggerControlEvent(
      widget.control, _maximized ? "maximize" : "restore", "");
  }

  void _onClose() {
    _visible = false;
    setState(() {});
    FletBackend.of(context).updateControl(
      widget.control.id, {'win_visible': 'false'});
    FletBackend.of(context).triggerControlEvent(
      widget.control, "close", "");
  }

  void _sendPositionToBackend() {
    final r = _rect.value;
    FletBackend.of(context).updateControl(widget.control.id, {
      'win_left': r.left.toString(),
      'win_top': r.top.toString(),
      'win_width': r.width.toString(),
      'win_height': r.height.toString(),
    });
  }
}

/// A small icon button with hover highlight for window chrome.
class _HoverIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color hoverColor;
  final double size;

  const _HoverIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.hoverColor,
    required this.size,
  });

  @override
  State<_HoverIconButton> createState() => _HoverIconButtonState();
}

class _HoverIconButtonState extends State<_HoverIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Tooltip(
          message: widget.tooltip,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hovering ? widget.hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: const Color(0xFFCCCCCC),
            ),
          ),
        ),
      ),
    );
  }
}
