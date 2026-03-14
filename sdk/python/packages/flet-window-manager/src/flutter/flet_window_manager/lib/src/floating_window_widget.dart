import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A single floating window with title bar, resize handles, and window buttons.
///
/// All drag/resize handled at 60fps via setState(). Final positions sent to
/// Python only on gesture end via FletBackend.updateControl().
///
/// Architecture: renders SizedBox.expand → Stack → Positioned so that
/// the Positioned is always a direct Stack child (required by Flutter).
/// This also means hit-testing only triggers on the window chrome area,
/// not the full overlay — clicks outside pass through to the doclet.
class FloatingWindowWidget extends StatefulWidget {
  final Control control;

  const FloatingWindowWidget({
    super.key,
    required this.control,
  });

  @override
  State<FloatingWindowWidget> createState() => _FloatingWindowWidgetState();
}

class _FloatingWindowWidgetState extends State<FloatingWindowWidget> {
  // Current window geometry (Dart-local state for 60fps updates)
  double _left = 100;
  double _top = 100;
  double _width = 800;
  double _height = 400;

  // Saved rect for maximize/restore
  double _savedLeft = 0;
  double _savedTop = 0;
  double _savedWidth = 0;
  double _savedHeight = 0;

  bool _maximized = false;
  bool _visible = true;

  // Track whether we've initialized from control properties
  bool _initialized = false;

  static const double _titleBarHeight = 32.0;
  static const double _resizeHandleSize = 6.0;
  static const double _minWidth = 200.0;
  static const double _minHeight = 100.0;

  @override
  void initState() {
    super.initState();
    _syncFromControl();
  }

  @override
  void didUpdateWidget(covariant FloatingWindowWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFromControl();
  }

  /// Read values from Python control properties.
  ///
  /// Position and maximize state are only read on first build (initialization).
  /// After that, Dart owns these values locally for 60fps drag/resize — Python
  /// only gets updates on gesture end via updateControl(). The visibility
  /// property is always synced since it's toggled from Python.
  void _syncFromControl() {
    final c = widget.control;

    // Visibility: always sync from Python (Python owns show/hide)
    _visible = c.getBool("win_visible", true)!;

    // Position, size, maximize: only read on first build
    if (!_initialized) {
      _left = c.getDouble("win_left", 100)!;
      _top = c.getDouble("win_top", 100)!;
      _width = c.getDouble("win_width", 800)!;
      _height = c.getDouble("win_height", 400)!;
      _maximized = c.getBool("maximized", false)!;
      _initialized = true;
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
    final title = widget.control.getString("title") ?? "";
    final titleBarColor =
        _parseColor(widget.control.getString("title_bar_color"), const Color(0xFF1E1E2E));
    final chromeColor =
        _parseColor(widget.control.getString("chrome_color"), const Color(0xFF26252D));

    // SizedBox.expand fills the overlay area, then our inner Stack + Positioned
    // places the window at _left/_top. Hit-testing only fires on the Positioned
    // child — clicks outside the window chrome pass through to the doclet.
    return LayoutControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vpWidth = constraints.maxWidth;
          final vpHeight = constraints.maxHeight;

          double effectiveLeft, effectiveTop, effectiveWidth, effectiveHeight;
          if (_maximized) {
            effectiveLeft = 0;
            effectiveTop = 0;
            effectiveWidth = vpWidth;
            effectiveHeight = vpHeight;
          } else {
            effectiveLeft = _left;
            effectiveTop = _top;
            effectiveWidth = _width.clamp(_minWidth, vpWidth);
            effectiveHeight = _height.clamp(_minHeight, vpHeight);
          }

          // Use opacity to hide — NOT removal from tree (preserves WebView iframes).
          // IgnorePointer wraps the entire SizedBox.expand so the full overlay
          // area passes through hits when the window is hidden.
          final effectiveOpacity = _visible ? 1.0 : 0.0;

          return IgnorePointer(
            ignoring: !_visible,
            child: SizedBox.expand(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: effectiveLeft,
                    top: effectiveTop,
                    child: Opacity(
                      opacity: effectiveOpacity,
                      child: SizedBox(
                        width: effectiveWidth,
                        height: effectiveHeight,
                        child: _buildWindowChrome(
                          title,
                          titleBarColor,
                          chromeColor,
                          vpWidth,
                          vpHeight,
                          effectiveWidth,
                          effectiveHeight,
                        ),
                      ),
                    ),
                  ),
                ],
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
    double vpWidth,
    double vpHeight,
    double windowWidth,
    double windowHeight,
  ) {
    final children = widget.control.buildWidgets("controls");

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Main window body with shadow
        Container(
          decoration: BoxDecoration(
            color: chromeColor,
            borderRadius: BorderRadius.circular(8),
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
              _buildTitleBar(title, titleBarColor, vpWidth, vpHeight),
              // Content area
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                  child: children.isNotEmpty
                      ? children.first
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),

        // Resize handles (only when not maximized)
        if (!_maximized) ..._buildResizeHandles(vpWidth, vpHeight, windowWidth, windowHeight),
      ],
    );
  }

  Widget _buildTitleBar(String title, Color titleBarColor, double vpWidth, double vpHeight) {
    return GestureDetector(
      onPanUpdate: _maximized
          ? null
          : (details) {
              setState(() {
                _left = (_left + details.delta.dx).clamp(
                    -_width + 100, vpWidth - 100);
                _top = (_top + details.delta.dy).clamp(0.0, vpHeight - _titleBarHeight);
              });
            },
      onPanEnd: _maximized
          ? null
          : (_) {
              _sendPositionToBackend();
            },
      onDoubleTap: _toggleMaximize,
      child: Container(
        height: _titleBarHeight,
        decoration: BoxDecoration(
          color: titleBarColor,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(8),
            topRight: Radius.circular(8),
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
            // Window buttons
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

  List<Widget> _buildResizeHandles(
    double vpWidth, double vpHeight, double windowWidth, double windowHeight,
  ) {
    return [
      // Top edge
      _resizeHandle(
        cursor: SystemMouseCursors.resizeUp,
        left: _resizeHandleSize,
        top: 0,
        width: windowWidth - _resizeHandleSize * 2,
        height: _resizeHandleSize,
        onDrag: (dx, dy) => _resizeTop(dy, vpHeight),
      ),
      // Bottom edge
      _resizeHandle(
        cursor: SystemMouseCursors.resizeDown,
        left: _resizeHandleSize,
        top: windowHeight - _resizeHandleSize,
        width: windowWidth - _resizeHandleSize * 2,
        height: _resizeHandleSize,
        onDrag: (dx, dy) => _resizeBottom(dy, vpHeight),
      ),
      // Left edge
      _resizeHandle(
        cursor: SystemMouseCursors.resizeLeft,
        left: 0,
        top: _resizeHandleSize,
        width: _resizeHandleSize,
        height: windowHeight - _resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeLeft(dx, vpWidth),
      ),
      // Right edge
      _resizeHandle(
        cursor: SystemMouseCursors.resizeRight,
        left: windowWidth - _resizeHandleSize,
        top: _resizeHandleSize,
        width: _resizeHandleSize,
        height: windowHeight - _resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeRight(dx, vpWidth),
      ),
      // Top-left corner
      _resizeHandle(
        cursor: SystemMouseCursors.resizeUpLeft,
        left: 0,
        top: 0,
        width: _resizeHandleSize,
        height: _resizeHandleSize,
        onDrag: (dx, dy) {
          _resizeLeft(dx, vpWidth);
          _resizeTop(dy, vpHeight);
        },
      ),
      // Top-right corner
      _resizeHandle(
        cursor: SystemMouseCursors.resizeUpRight,
        left: windowWidth - _resizeHandleSize,
        top: 0,
        width: _resizeHandleSize,
        height: _resizeHandleSize,
        onDrag: (dx, dy) {
          _resizeRight(dx, vpWidth);
          _resizeTop(dy, vpHeight);
        },
      ),
      // Bottom-left corner
      _resizeHandle(
        cursor: SystemMouseCursors.resizeDownLeft,
        left: 0,
        top: windowHeight - _resizeHandleSize,
        width: _resizeHandleSize,
        height: _resizeHandleSize,
        onDrag: (dx, dy) {
          _resizeLeft(dx, vpWidth);
          _resizeBottom(dy, vpHeight);
        },
      ),
      // Bottom-right corner
      _resizeHandle(
        cursor: SystemMouseCursors.resizeDownRight,
        left: windowWidth - _resizeHandleSize,
        top: windowHeight - _resizeHandleSize,
        width: _resizeHandleSize,
        height: _resizeHandleSize,
        onDrag: (dx, dy) {
          _resizeRight(dx, vpWidth);
          _resizeBottom(dy, vpHeight);
        },
      ),
    ];
  }

  Widget _resizeHandle({
    required SystemMouseCursor cursor,
    required double left,
    required double top,
    required double width,
    required double height,
    required void Function(double dx, double dy) onDrag,
  }) {
    return Positioned(
      left: left,
      top: top,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              onDrag(details.delta.dx, details.delta.dy);
            });
          },
          onPanEnd: (_) {
            _sendPositionToBackend();
          },
          child: Container(
            width: width,
            height: height,
            color: Colors.transparent,
          ),
        ),
      ),
    );
  }

  // Resize helpers — mutate _left/_top/_width/_height in place

  void _resizeLeft(double dx, double vpWidth) {
    final newLeft = _left + dx;
    final newWidth = _width - dx;
    if (newWidth >= _minWidth && newLeft >= -50) {
      _left = newLeft;
      _width = newWidth;
    }
  }

  void _resizeRight(double dx, double vpWidth) {
    final newWidth = _width + dx;
    if (newWidth >= _minWidth && _left + newWidth <= vpWidth + 50) {
      _width = newWidth;
    }
  }

  void _resizeTop(double dy, double vpHeight) {
    final newTop = _top + dy;
    final newHeight = _height - dy;
    if (newHeight >= _minHeight && newTop >= 0) {
      _top = newTop;
      _height = newHeight;
    }
  }

  void _resizeBottom(double dy, double vpHeight) {
    final newHeight = _height + dy;
    if (newHeight >= _minHeight && _top + newHeight <= vpHeight + 50) {
      _height = newHeight;
    }
  }

  void _toggleMaximize() {
    setState(() {
      if (_maximized) {
        // Restore
        _left = _savedLeft;
        _top = _savedTop;
        _width = _savedWidth;
        _height = _savedHeight;
        _maximized = false;
      } else {
        // Save current rect
        _savedLeft = _left;
        _savedTop = _top;
        _savedWidth = _width;
        _savedHeight = _height;
        _maximized = true;
      }
    });
    FletBackend.of(context).updateControl(
      widget.control.id,
      {
        'maximized': _maximized.toString(),
        'win_left': _left.toString(),
        'win_top': _top.toString(),
        'win_width': _width.toString(),
        'win_height': _height.toString(),
      },
    );
    FletBackend.of(context).triggerControlEvent(
      widget.control,
      _maximized ? "maximize" : "restore",
      "",
    );
  }

  void _onClose() {
    setState(() => _visible = false);
    FletBackend.of(context).updateControl(
      widget.control.id,
      {'win_visible': 'false'},
    );
    FletBackend.of(context).triggerControlEvent(
      widget.control,
      "close",
      "",
    );
  }

  void _sendPositionToBackend() {
    FletBackend.of(context).updateControl(
      widget.control.id,
      {
        'win_left': _left.toString(),
        'win_top': _top.toString(),
        'win_width': _width.toString(),
        'win_height': _height.toString(),
      },
    );
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
