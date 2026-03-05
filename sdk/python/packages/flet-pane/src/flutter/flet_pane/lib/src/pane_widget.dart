import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';

import 'gutter_row.dart';

/// Main PaneWidget — custom Dart pane with 60fps gutter alley.
///
/// Supports two orientations:
///   vertical   — gutter on left edge,  hover detection by X position
///   horizontal — gutter on bottom edge, hover detection by Y position
///
/// Hover strategy: A single MouseRegion wraps the entire pane. On every
/// pointer move, we check the cursor position against the gutter zone.
/// This avoids all hit-test blocking — scroll, click, etc. all pass through.
/// The entire animation runs in Dart at 60fps with zero Python round-trips.
class PaneWidget extends StatefulWidget {
  final Control control;

  const PaneWidget({super.key, required this.control});

  @override
  State<PaneWidget> createState() => _PaneWidgetState();
}

class _PaneWidgetState extends State<PaneWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _gutterAnim;
  late Animation<double> _gutterWidth;
  late Animation<double> _contentOffset; // left (vertical) or bottom (horizontal)
  late Animation<double> _iconOpacity;
  late Animation<Color?> _gutterBgColor;

  late ScrollController _scrollController;
  bool _atTop = true;
  bool _atBottom = true;
  bool _isExpanded = false;

  // Cached gutter metadata (parsed from JSON once per config update)
  List<Map<String, dynamic>>? _gutterMetaList;

  // MicroPython formula strings (evaluated client-side per row)
  String? _colorFormula;
  String? _widthFormula;
  String? _opacityFormula;

  // Formula evaluation cache: "formula|contextHash" → result
  final Map<String, dynamic> _formulaCache = {};

  // Orientation: false = vertical (gutter left), true = horizontal (gutter bottom)
  bool _isHorizontal = false;

  // Layout dimensions (height for hover detection, width for horizontal item sizing)
  double _layoutHeight = 0;
  double _layoutWidth = 0;

  // Active item index for horizontal mode (which item is in view)
  int _activeIndex = 0;

  // Config from Python control
  double _idleWidth = 18;
  double _hoverWidth = 66;
  int _animationMs = 180;
  Color _gutterColor = const Color(0xFF0F1215);
  Color _bgColor = Colors.transparent;
  double _borderRadius = 0;
  double _paddingRight = 8;
  double _paddingTop = 4;
  double _paddingBottom = 4;
  double _arrowSize = 32;
  int _arrowFadeMs = 150;
  double _dimOpacity = 0.3;

  @override
  void initState() {
    super.initState();
    _parseConfig();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScrollUpdate);

    _gutterAnim = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _animationMs),
    );
    _gutterAnim.addListener(() => setState(() {}));
    _setupAnimations();
  }

  @override
  void didUpdateWidget(covariant PaneWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseConfig();
    _gutterAnim.duration = Duration(milliseconds: _animationMs);
    _setupAnimations();
  }

  void _parseConfig() {
    _isHorizontal =
        (widget.control.getString("orientation") ?? 'vertical') == 'horizontal';
    _idleWidth = widget.control.getDouble("gutter_width_idle") ?? 18;
    _hoverWidth = widget.control.getDouble("gutter_width_hover") ?? 66;
    _animationMs = widget.control.getInt("animation_ms") ?? 180;
    _paddingRight = widget.control.getDouble("padding_right") ?? 8;
    _paddingTop = widget.control.getDouble("padding_top") ?? 4;
    _paddingBottom = widget.control.getDouble("padding_bottom") ?? 4;
    _arrowSize = widget.control.getDouble("arrow_size") ?? 32;
    _arrowFadeMs = widget.control.getInt("arrow_fade_ms") ?? 150;
    _dimOpacity = widget.control.getDouble("dim_opacity") ?? 0.3;

    final gutterColorStr = widget.control.getString("gutter_color");
    if (gutterColorStr != null) {
      _gutterColor = _parseColor(gutterColorStr, const Color(0xFF0F1215))!;
    }

    final bgColorStr = widget.control.getString("bgcolor");
    if (bgColorStr != null) {
      _bgColor = _parseColor(bgColorStr, Colors.transparent)!;
    }

    _borderRadius = widget.control.getDouble("border_radius") ?? 0;

    // MicroPython formulas
    _colorFormula = widget.control.getString("gutter_color_formula");
    _widthFormula = widget.control.getString("gutter_width_formula");
    _opacityFormula = widget.control.getString("gutter_opacity_formula");

    // Clear formula cache when config changes
    _formulaCache.clear();

    // Parse gutter metadata JSON list
    final metaJson = widget.control.getString("gutter_metadata");
    if (metaJson != null && metaJson.isNotEmpty) {
      try {
        final list = jsonDecode(metaJson) as List;
        _gutterMetaList = list.cast<Map<String, dynamic>>();
      } catch (_) {
        _gutterMetaList = null;
      }
    } else {
      _gutterMetaList = null;
    }
  }

  void _setupAnimations() {
    _gutterWidth = Tween<double>(
      begin: _idleWidth,
      end: _hoverWidth,
    ).animate(CurvedAnimation(
      parent: _gutterAnim,
      curve: Curves.easeOut,
    ));

    _contentOffset = Tween<double>(
      begin: _idleWidth + 2,
      end: _hoverWidth + 2,
    ).animate(CurvedAnimation(
      parent: _gutterAnim,
      curve: Curves.easeOut,
    ));

    _iconOpacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _gutterAnim,
      curve: Curves.easeOut,
    ));

    _gutterBgColor = ColorTween(
      begin: Colors.transparent,
      end: _gutterColor,
    ).animate(CurvedAnimation(
      parent: _gutterAnim,
      curve: Curves.easeOut,
    ));
  }

  @override
  void dispose() {
    _gutterAnim.dispose();
    _scrollController.removeListener(_onScrollUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  // ── Hover (position-based detection) ───────────────────────────────

  void _onHover(PointerEvent event) {
    if (_isHorizontal) {
      // Horizontal: gutter at bottom — expand when cursor near bottom edge
      if (event.localPosition.dy > (_layoutHeight - _hoverWidth)) {
        _expandAlley();
      } else {
        _collapseAlley();
      }
    } else {
      // Vertical: gutter at left — expand when cursor near left edge
      if (event.localPosition.dx < _hoverWidth) {
        _expandAlley();
      } else {
        _collapseAlley();
      }
    }
  }

  void _onExit(PointerEvent event) {
    _collapseAlley();
  }

  void _expandAlley() {
    if (!_isExpanded) {
      setState(() => _isExpanded = true);
      _gutterAnim.forward();
    }
  }

  void _collapseAlley() {
    if (_isExpanded) {
      setState(() => _isExpanded = false);
      _gutterAnim.reverse();
    }
  }

  // ── Scroll tracking ────────────────────────────────────────────────

  void _onScrollUpdate() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final newAtTop = pos.pixels <= pos.minScrollExtent + 1;
    final newAtBottom = pos.pixels >= pos.maxScrollExtent - 1;

    // Track active index for horizontal mode
    int newActiveIndex = _activeIndex;
    if (_isHorizontal && _layoutWidth > 0) {
      newActiveIndex = (pos.pixels / _layoutWidth).round().clamp(0,
          (pos.maxScrollExtent / _layoutWidth).ceil());
    }

    if (newAtTop != _atTop || newAtBottom != _atBottom ||
        newActiveIndex != _activeIndex) {
      setState(() {
        _atTop = newAtTop;
        _atBottom = newAtBottom;
        _activeIndex = newActiveIndex;
      });
    }

    // Fire Python on_scroll event if registered
    if (widget.control.getBool("on_scroll", false) == true) {
      widget.control.triggerEvent("scroll", {
        "pixels": pos.pixels,
        "min": pos.minScrollExtent,
        "max": pos.maxScrollExtent,
      });
    }
  }

  void _scrollUp() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      (_scrollController.offset - 200).clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _scrollDown() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      (_scrollController.offset + 200).clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // ── Horizontal page-based scrolling ─────────────────────────────────

  void _scrollLeft() {
    if (!_scrollController.hasClients || _layoutWidth <= 0) return;
    final prevIndex = (_activeIndex - 1).clamp(0, _activeIndex);
    final target = prevIndex * _layoutWidth;
    _scrollController.animateTo(
      target.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollRight() {
    if (!_scrollController.hasClients || _layoutWidth <= 0) return;
    final target = (_activeIndex + 1) * _layoutWidth;
    _scrollController.animateTo(
      target.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollToStart() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollToEnd() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final childControls = widget.control.children("controls");

    // Only use LayoutBuilder for horizontal mode (needs layout height for
    // Y-position hover detection). Vertical mode uses no LayoutBuilder —
    // adding one breaks Flet's LayoutControl constraint negotiation.
    Widget content;
    if (_isHorizontal) {
      content = LayoutBuilder(
        builder: (context, constraints) {
          _layoutHeight = constraints.maxHeight;
          _layoutWidth = constraints.maxWidth;
          return MouseRegion(
            onHover: _onHover,
            onExit: _onExit,
            child: _buildHorizontalContent(childControls),
          );
        },
      );
    } else {
      content = MouseRegion(
        onHover: _onHover,
        onExit: _onExit,
        child: _buildVerticalContent(childControls),
      );
    }

    return LayoutControl(
      control: widget.control,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_borderRadius),
        child: Container(
          color: _bgColor,
          child: content,
        ),
      ),
    );
  }

  /// Vertical layout: gutter on left, content scrolls vertically.
  Widget _buildVerticalContent(List<Control> childControls) {
    final arrowBtnSize = _arrowSize + 16;
    final arrowLeft = (_hoverWidth - arrowBtnSize) / 2;

    return Stack(
      children: [
        Positioned.fill(
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.only(
              right: _paddingRight,
              top: _paddingTop,
              bottom: _paddingBottom,
            ),
            itemCount: childControls.length,
            cacheExtent: 500,
            itemBuilder: (context, index) {
              final child = childControls[index];
              final meta = _getGutterMeta(index);
              final gutterIcon = (meta?['gutter_thumbnail'] ?? meta?['gutter_icon']) as String?;
              final indicatorColor = _resolveIndicatorColor(meta);

              return GutterRow(
                key: ValueKey(child.id),
                control: child,
                gutterWidth: _gutterWidth,
                contentOffset: _contentOffset,
                iconOpacity: _iconOpacity,
                gutterBgColor: _gutterBgColor,
                gutterIcon: gutterIcon,
                indicatorColor: indicatorColor,
                hoverWidth: _hoverWidth,
                isHorizontal: false,
                onGutterTap: () {
                  widget.control.triggerEvent("gutter_tap", {"index": index});
                },
              );
            },
          ),
        ),

        // Scroll-up arrow
        if (_isExpanded)
          Positioned(
            left: arrowLeft,
            top: 0,
            child: _buildArrowButton(
              icon: Icons.keyboard_arrow_up,
              onTap: _scrollUp,
              onDoubleTap: _scrollToTop,
              dimmed: _atTop,
            ),
          ),

        // Scroll-down arrow
        if (_isExpanded)
          Positioned(
            left: arrowLeft,
            bottom: 0,
            child: _buildArrowButton(
              icon: Icons.keyboard_arrow_down,
              onTap: _scrollDown,
              onDoubleTap: _scrollToBottom,
              dimmed: _atBottom,
            ),
          ),
      ],
    );
  }

  /// Horizontal layout: gutter strip at bottom, content scrolls horizontally.
  ///
  /// Scrolling strategy: NeverScrollableScrollPhysics disables the ListView's
  /// built-in Scrollable (which would claim pointer-signal events and then
  /// discard vertical deltas). Instead we handle ALL scrolling manually:
  ///   - GestureDetector.onHorizontalDragUpdate → drag to scroll
  ///   - Listener.onPointerSignal → mouse wheel (vertical delta → horizontal)
  Widget _buildHorizontalContent(List<Control> childControls) {
    return Stack(
      children: [
        // Main content: horizontal scroll area above the gutter strip.
        // SuperPlot claims all pointer events inside charts, so we
        // don't try to handle scroll/drag here.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: _gutterWidth.value,
          // SingleChildScrollView + Row: eagerly builds ALL children so
          // platform views (WebView iframes) are never destroyed by cache
          // eviction.  Horizontal panes have few items (3-7) so no cost.
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              children: childControls.map((child) => SizedBox(
                key: ValueKey(child.id),
                width: _layoutWidth,
                child: Padding(
                  padding: EdgeInsets.all(_paddingTop),
                  child: ControlWidget(control: child),
                ),
              )).toList(),
            ),
          ),
        ),

        // Gutter strip at bottom — the tension-free swipe/scroll zone.
        // Handles horizontal drag + mouse wheel → horizontal scroll.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _gutterWidth.value,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Drag tracks the finger 1:1 (jumpTo for immediacy)
            onHorizontalDragUpdate: (details) {
              if (_scrollController.hasClients) {
                final pos = _scrollController.position;
                final newOffset =
                    (_scrollController.offset - details.delta.dx)
                        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
                _scrollController.jumpTo(newOffset);
              }
            },
            // On release, coast with momentum based on fling velocity
            onHorizontalDragEnd: (details) {
              if (!_scrollController.hasClients) return;
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 50) return; // ignore tiny flicks
              final pos = _scrollController.position;
              // Friction factor: higher = more coast distance
              final target = (_scrollController.offset - velocity * 0.4)
                  .clamp(pos.minScrollExtent, pos.maxScrollExtent);
              _scrollController.animateTo(
                target,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
              );
            },
            child: Listener(
              onPointerSignal: (event) {
                // Mouse wheel: smooth animated scroll instead of jumpTo
                if (event is PointerScrollEvent &&
                    _scrollController.hasClients) {
                  final pos = _scrollController.position;
                  final newOffset = (_scrollController.offset +
                          event.scrollDelta.dy)
                      .clamp(pos.minScrollExtent, pos.maxScrollExtent);
                  _scrollController.animateTo(
                    newOffset,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  );
                }
              },
              child: CustomPaint(
                painter: _HorizontalGutterPainter(
                  backgroundColor:
                      _gutterBgColor.value ?? Colors.transparent,
                ),
                child: _buildHorizontalGutterContent(childControls),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Build horizontal gutter indicator row (icons + indicators arranged horizontally).
  /// Scrollable, with the active item highlighted.
  Widget _buildHorizontalGutterContent(List<Control> childControls) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          for (int i = 0; i < childControls.length; i++)
            _buildHorizontalGutterItem(i),
        ],
      ),
    );
  }

  Widget _buildHorizontalGutterItem(int index) {
    final meta = _getGutterMeta(index);
    final gutterIcon = (meta?['gutter_thumbnail'] ?? meta?['gutter_icon']) as String?;
    final indicatorColor = _resolveIndicatorColor(meta);
    final isActive = index == _activeIndex;
    final cellWidth = _gutterWidth.value.clamp(18.0, 48.0);

    return GestureDetector(
      onTap: () {
        // Tap gutter item to scroll to that item
        if (_scrollController.hasClients && _layoutWidth > 0) {
          _scrollController.animateTo(
            (index * _layoutWidth).clamp(
              _scrollController.position.minScrollExtent,
              _scrollController.position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        widget.control.triggerEvent("gutter_tap", {"index": index});
      },
      child: Container(
        width: cellWidth,
        height: _gutterWidth.value,
        decoration: isActive
            ? BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: indicatorColor ?? Colors.white70,
                    width: 2,
                  ),
                ),
              )
            : null,
        child: Stack(
          children: [
            // Indicator glow
            if (indicatorColor != null)
              Positioned.fill(
                child: CustomPaint(
                  painter: _IndicatorDotPainter(
                    color: indicatorColor,
                    opacity: isActive
                        ? 1.0
                        : _iconOpacity.value * 0.5,
                  ),
                ),
              ),
            // Icon
            if (gutterIcon != null)
              Center(
                child: Opacity(
                  opacity: isActive ? 1.0 : _iconOpacity.value,
                  child: GutterRow.buildIconFromBase64(gutterIcon, 24),
                ),
              ),
            // Dot indicator when collapsed (no icon)
            if (gutterIcon == null)
              Center(
                child: Container(
                  width: isActive ? 8 : 4,
                  height: isActive ? 8 : 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? (indicatorColor ?? Colors.white70)
                        : (indicatorColor ?? Colors.white30)
                            .withValues(alpha: _iconOpacity.value),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildArrowButton({
    required IconData icon,
    required VoidCallback onTap,
    required VoidCallback onDoubleTap,
    required bool dimmed,
  }) {
    final btnSize = _arrowSize + 16;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: AnimatedOpacity(
        opacity: dimmed ? _dimOpacity : 1.0,
        duration: Duration(milliseconds: _arrowFadeMs),
        child: Container(
          width: btnSize,
          height: btnSize,
          decoration: BoxDecoration(
            color: _gutterColor,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: _arrowSize, color: Colors.white70),
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────

  Map<String, dynamic>? _getGutterMeta(int index) {
    if (_gutterMetaList == null || index >= _gutterMetaList!.length) {
      return null;
    }
    return _gutterMetaList![index];
  }

  /// Evaluate a MicroPython formula with the item's metadata as context.
  String? _evalFormula(String formula, Map<String, dynamic> context) {
    if (!MicroPythonService.isReady) return null;

    final cacheKey = '$formula|${context.hashCode}';
    if (_formulaCache.containsKey(cacheKey)) {
      return _formulaCache[cacheKey] as String?;
    }

    try {
      final result = MicroPythonService.fmt(formula, context);
      if (_formulaCache.length > 200) _formulaCache.clear();
      _formulaCache[cacheKey] = result;
      return result;
    } catch (e) {
      debugPrint('[PaneWidget] Formula eval error: $e');
      return null;
    }
  }

  /// Resolve the indicator color for a row, using formula if available.
  Color? _resolveIndicatorColor(Map<String, dynamic>? meta) {
    if (meta == null) return null;

    if (_colorFormula != null) {
      final result = _evalFormula(_colorFormula!, meta);
      if (result != null) {
        final color = _parseColor(result, null);
        if (color != null) return color;
      }
    }

    final colorStr = meta['gutter_color'] as String?;
    return colorStr != null ? _parseColor(colorStr, null) : null;
  }

  static Color? _parseColor(String colorStr, Color? defaultColor) {
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      if (hex.length == 8) {
        final value = int.tryParse(hex, radix: 16);
        if (value != null) return Color(value);
      }
    }
    return defaultColor;
  }
}

// ── Private painters for horizontal layout ──────────────────────────

/// Simple background painter for the horizontal gutter strip.
class _HorizontalGutterPainter extends CustomPainter {
  final Color backgroundColor;

  _HorizontalGutterPainter({required this.backgroundColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (backgroundColor != Colors.transparent) {
      canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    }
  }

  @override
  bool shouldRepaint(_HorizontalGutterPainter old) =>
      old.backgroundColor != backgroundColor;
}

/// Radial indicator dot painter for each horizontal gutter item.
class _IndicatorDotPainter extends CustomPainter {
  final Color color;
  final double opacity;

  _IndicatorDotPainter({required this.color, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity < 0.01) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.4;
    final gradient = RadialGradient(
      center: Alignment.center,
      radius: 0.8,
      colors: [
        color.withValues(alpha: opacity * 0.6),
        color.withValues(alpha: 0),
      ],
    );
    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromCircle(center: center, radius: radius),
      );
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_IndicatorDotPainter old) =>
      old.color != color || old.opacity != opacity;
}
