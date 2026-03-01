import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';

import 'gutter_row.dart';

/// Main PaneWidget — custom Dart pane with 60fps gutter alley.
///
/// Hover strategy: A single MouseRegion wraps the entire pane. On every
/// pointer move, we check if cursor X < hoverWidth to decide expand/collapse.
/// This avoids all hit-test blocking — scroll and click events reach the
/// ListView unimpeded. The entire animation runs in Dart at 60fps with
/// zero Python round-trips.
///
/// Architecture:
///   MouseRegion (whole pane — hover detection by X position)
///   └── Stack
///       ├── ListView.builder          ← LOD: only builds visible rows
///       │   └── GutterRow (per item)  ← per-row gutter + child widget
///       ├── Positioned(top-left)      ← scroll-up arrow
///       └── Positioned(bottom-left)   ← scroll-down arrow
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
  late Animation<double> _contentLeft;
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

    _contentLeft = Tween<double>(
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
    // Expand when cursor is within the gutter detection zone
    if (event.localPosition.dx < _hoverWidth) {
      _expandAlley();
    } else {
      _collapseAlley();
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
    if (newAtTop != _atTop || newAtBottom != _atBottom) {
      setState(() {
        _atTop = newAtTop;
        _atBottom = newAtBottom;
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

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final childControls = widget.control.children("controls");

    return LayoutControl(
      control: widget.control,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_borderRadius),
        child: Container(
          color: _bgColor,
          // Wrap entire pane in MouseRegion for position-based hover detection.
          // This doesn't block any events — scroll, click, etc. all pass through.
          // Animation rebuilds via _gutterAnim.addListener(() => setState((){})).
          child: MouseRegion(
            onHover: _onHover,
            onExit: _onExit,
            child: _buildContent(childControls),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(List<Control> childControls) {
    final arrowBtnSize = _arrowSize + 16;
    final arrowLeft = (_hoverWidth - arrowBtnSize) / 2;

    return Stack(
      children: [
        // ── Main content: ListView.builder with gutter rows ──
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
              final gutterIcon = meta?['gutter_icon'] as String?;
              final indicatorColor = _resolveIndicatorColor(meta);

              return GutterRow(
                key: ValueKey(child.id),
                control: child,
                gutterWidth: _gutterWidth,
                contentLeft: _contentLeft,
                iconOpacity: _iconOpacity,
                gutterBgColor: _gutterBgColor,
                gutterIcon: gutterIcon,
                indicatorColor: indicatorColor,
                hoverWidth: _hoverWidth,
                onGutterTap: () {
                  widget.control.triggerEvent("gutter_tap", {"index": index});
                },
              );
            },
          ),
        ),

        // ── Scroll-up arrow (only when expanded) ──
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

        // ── Scroll-down arrow (only when expanded) ──
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
  /// Returns null on error or if MicroPython isn't ready.
  /// Uses fmt() for f-string evaluation (same pattern as SuperPlot tooltips).
  String? _evalFormula(String formula, Map<String, dynamic> context) {
    if (!MicroPythonService.isReady) return null;

    // Cache key: formula + serialized context
    final cacheKey = '$formula|${context.hashCode}';
    if (_formulaCache.containsKey(cacheKey)) {
      return _formulaCache[cacheKey] as String?;
    }

    try {
      final result = MicroPythonService.fmt(formula, context);
      // Limit cache size
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

    // Try formula first
    if (_colorFormula != null) {
      final result = _evalFormula(_colorFormula!, meta);
      if (result != null) {
        final color = _parseColor(result, null);
        if (color != null) return color;
      }
    }

    // Fallback to static color from metadata
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
