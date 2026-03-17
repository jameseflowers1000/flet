import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flet/flet.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';

import 'gutter_row.dart';

/// Gallery thumbnail position descriptor.
class _ThumbPosition {
  final int index;
  final double offset; // position along main axis (top-left corner)
  final double scale; // 1.0 at center, decreasing outward
  final int zOrder; // higher = painted later (on top)

  const _ThumbPosition({
    required this.index,
    required this.offset,
    required this.scale,
    required this.zOrder,
  });
}

/// Per-control sizing metadata extracted from gutter_metadata.
class _ItemSizing {
  final double? preferredSize;  // user-set pixel size (from drag)
  final double? absoluteSize;   // fixed pixel size (from dialog)
  final double? aspectRatio;    // width / height
  final double flex;            // proportional weight
  final double? minSize;
  final double? maxSize;

  const _ItemSizing({
    this.preferredSize,
    this.absoluteSize,
    this.aspectRatio,
    required this.flex,
    this.minSize,
    this.maxSize,
  });
}

/// Main PaneWidget — custom Dart pane with gallery gutter.
///
/// Supports two orientations:
///   vertical   — gutter on left edge,  hover detection by X position
///   horizontal — gutter on bottom edge, hover detection by Y position
///
/// Gallery: thumbnails fan out from center based on scroll position.
/// Hover preview: thumbnail pop-out after 1s hover delay.
/// Context menu: right-click fires gutter_context event to Python.
class PaneWidget extends StatefulWidget {
  final Control control;

  const PaneWidget({super.key, required this.control});

  @override
  State<PaneWidget> createState() => _PaneWidgetState();
}

class _PaneWidgetState extends State<PaneWidget>
    with SingleTickerProviderStateMixin {
  // Static: survives widget State recreation by Flet reconciliation
  static String _globalSizingMode = 'natural';
  static int _globalModeGen = 0;

  // ── Animation ─────────────────────────────────────────────────────
  late AnimationController _gutterAnim;
  late Animation<double> _gutterWidth;
  late Animation<double> _contentOffset; // left (vertical) or bottom (horizontal)
  late Animation<double> _iconOpacity;
  late Animation<Color?> _gutterBgColor;

  // ── Scroll & state ────────────────────────────────────────────────
  late ScrollController _scrollController;
  bool _atTop = true;
  bool _atBottom = true;
  bool _isExpanded = false;
  int _activeIndex = 0;

  // ── Gutter metadata ───────────────────────────────────────────────
  List<Map<String, dynamic>>? _gutterMetaList;
  String? _colorFormula;
  String? _widthFormula;
  String? _opacityFormula;
  final Map<String, dynamic> _formulaCache = {};

  // ── Orientation & layout ──────────────────────────────────────────
  bool _isHorizontal = false;
  String _sizingMode = 'natural'; // 'natural' | 'gallery' | 'fit'
  int _modeGen = 0; // generation counter — prevents stale metadata overwrite
  double _layoutHeight = 0;
  double _layoutWidth = 0;

  // ── Hover preview ─────────────────────────────────────────────────
  Timer? _hoverTimer;
  OverlayEntry? _previewOverlay;

  // ── Config ────────────────────────────────────────────────────────
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
    final oldMode = _sizingMode;
    _parseConfig();
    if (_sizingMode != oldMode) {
      // Mode changed: $oldMode → $_sizingMode
    }
    _gutterAnim.duration = Duration(milliseconds: _animationMs);
    _setupAnimations();
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _previewOverlay?.remove();
    _gutterAnim.dispose();
    _scrollController.removeListener(_onScrollUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  // ── Config parsing ──────────────────────────────────────────────────

  void _parseConfig() {
    _isHorizontal =
        (widget.control.getString("orientation") ?? 'vertical') == 'horizontal';
    final rawMode = widget.control.getString("sizing_mode");
    if (rawMode != null) {
      _sizingMode = rawMode;
    }
    // Debug: log every time config is parsed with raw value
    // print('[PaneWidget] parseConfig: raw sizing_mode=$rawMode → $_sizingMode');
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

    _colorFormula = widget.control.getString("gutter_color_formula");
    _widthFormula = widget.control.getString("gutter_width_formula");
    _opacityFormula = widget.control.getString("gutter_opacity_formula");
    _formulaCache.clear();

    final metaJson = widget.control.getString("gutter_metadata");
    if (metaJson != null && metaJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(metaJson);
        if (decoded is Map<String, dynamic>) {
          // New format: {"mode": "gallery", "items": [...]}
          final modeFromMeta = decoded['mode'] as String?;
          final genFromMeta = (decoded['gen'] as num?)?.toInt() ?? 0;
          if (modeFromMeta != null && genFromMeta >= _globalModeGen) {
            _globalSizingMode = modeFromMeta;
            _globalModeGen = genFromMeta;
          }
          _sizingMode = _globalSizingMode;
          // print('[PaneWidget] metadata mode=$modeFromMeta gen=$genFromMeta');
          final items = decoded['items'] as List?;
          _gutterMetaList = items?.cast<Map<String, dynamic>>();
        } else if (decoded is List) {
          // Legacy format: [...]
          // print('[PaneWidget] metadata legacy_array len=${decoded.length}');
          _gutterMetaList = decoded.cast<Map<String, dynamic>>();
        }
      } catch (e) {
        // print('[PaneWidget] metadata PARSE ERROR: $e');
        _gutterMetaList = null;
      }
    } else {
      // print('[PaneWidget] metadata EMPTY/NULL');
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

  // ── Hover (position-based detection) ───────────────────────────────

  void _onHover(PointerEvent event) {
    // Tight trigger zone: idle width + small margin (not the full hover width)
    final triggerZone = _idleWidth + 8;
    if (_isHorizontal) {
      if (event.localPosition.dy > (_layoutHeight - triggerZone)) {
        _expandAlley();
      } else if (!_isExpanded ||
          event.localPosition.dy < (_layoutHeight - _hoverWidth)) {
        _collapseAlley();
      }
    } else {
      if (event.localPosition.dx < triggerZone) {
        _expandAlley();
      } else if (!_isExpanded ||
          event.localPosition.dx > _hoverWidth) {
        _collapseAlley();
      }
    }
  }

  void _onExit(PointerEvent event) {
    _collapseAlley();
    _cancelHoverPreview();
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

    int newActiveIndex = _activeIndex;
    if (_isHorizontal && _layoutWidth > 0) {
      newActiveIndex = (pos.pixels / _layoutWidth).round().clamp(0,
          (pos.maxScrollExtent / _layoutWidth).ceil());
    } else if (!_isHorizontal) {
      final childCount = widget.control.children("controls").length;
      if (childCount > 1 && pos.maxScrollExtent > 0) {
        final fraction = pos.pixels / pos.maxScrollExtent;
        newActiveIndex =
            (fraction * (childCount - 1)).round().clamp(0, childCount - 1);
      } else {
        newActiveIndex = 0;
      }
    }

    if (newAtTop != _atTop || newAtBottom != _atBottom ||
        newActiveIndex != _activeIndex) {
      _cancelHoverPreview();
      setState(() {
        _atTop = newAtTop;
        _atBottom = newAtBottom;
        _activeIndex = newActiveIndex;
      });
    }

    if (widget.control.getBool("on_scroll", false) == true) {
      widget.control.triggerEvent("scroll", {
        "pixels": pos.pixels,
        "min": pos.minScrollExtent,
        "max": pos.maxScrollExtent,
      });
    }
  }

  // ── Scroll methods (vertical) ─────────────────────────────────────

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

  // ── Scroll methods (horizontal) ───────────────────────────────────

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

  // ── Gallery positioning ────────────────────────────────────────────

  /// Compute fractional scroll position (0.0 to 1.0).
  double _computeScrollFraction() {
    if (!_scrollController.hasClients) return 0;
    final pos = _scrollController.position;
    if (pos.maxScrollExtent <= 0) return 0;
    return (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
  }

  /// Fan-out positioning: center thumbnail at gutter midpoint,
  /// adjacent thumbnails spread outward with decreasing density.
  List<_ThumbPosition> _computeGalleryPositions({
    required int count,
    required double currentIndex,
    required double gutterLength,
    required double arrowReserve,
    required double thumbSize,
  }) {
    if (count == 0) return [];

    final usableLength = gutterLength - 2 * arrowReserve;
    final centerOffset = gutterLength / 2;

    // Graceful degrade: too small for gallery, show only current
    if (usableLength < thumbSize * 1.5) {
      final idx = currentIndex.round().clamp(0, count - 1);
      return [
        _ThumbPosition(
          index: idx,
          offset: centerOffset - thumbSize / 2,
          scale: 1.0,
          zOrder: count,
        )
      ];
    }

    final positions = <_ThumbPosition>[];
    for (int i = 0; i < count; i++) {
      final rawDist = i - currentIndex;
      final distance = rawDist.abs();
      final direction = rawDist >= 0 ? 1.0 : -1.0;

      double center;
      if (distance < 0.001) {
        center = centerOffset;
      } else if (distance <= 1) {
        center = centerOffset + direction * usableLength * 0.25 * distance;
      } else if (distance <= 2) {
        center = centerOffset +
            direction * usableLength * (0.25 + (distance - 1) * 0.125);
      } else {
        center = centerOffset +
            direction *
                usableLength *
                (0.5 - math.pow(0.5, distance) * 0.25);
      }

      // Convert center to top-left and clamp within usable area
      final offset = (center - thumbSize / 2)
          .clamp(arrowReserve, gutterLength - arrowReserve - thumbSize);

      final scale = 1.0 / (1.0 + distance * 0.12);
      final zOrder = (count - distance.ceil()).clamp(0, count);

      positions.add(_ThumbPosition(
        index: i,
        offset: offset,
        scale: scale,
        zOrder: zOrder,
      ));
    }

    return positions;
  }

  /// Scroll pane content to show item at [index].
  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final childCount = widget.control.children("controls").length;

    double target;
    if (_isHorizontal && _layoutWidth > 0) {
      target = index * _layoutWidth;
    } else if (childCount > 1 && pos.maxScrollExtent > 0) {
      target = (index / (childCount - 1)) * pos.maxScrollExtent;
    } else {
      return;
    }

    _scrollController.animateTo(
      target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ── Mode cycling ───────────────────────────────────────────────────

  static const _modeOrder = ['natural', 'gallery', 'fit'];
  static const _modeLabels = {'natural': 'N', 'gallery': 'G', 'fit': 'F'};
  static const _modeColors = {
    'natural': Color(0xFF4CAF50),  // green
    'gallery': Color(0xFF2196F3),  // blue
    'fit': Color(0xFFFF9800),      // orange
  };

  void _cycleMode() {
    final idx = _modeOrder.indexOf(_globalSizingMode);
    final next = _modeOrder[(idx + 1) % _modeOrder.length];
    _globalSizingMode = next;
    _globalModeGen++;
    _sizingMode = next;
    // Notify Python via event so it can persist
    widget.control.triggerEvent("mode_change", '{"mode":"$next","gen":$_globalModeGen}');
    setState(() {});
  }

  // ── Resize bars ────────────────────────────────────────────────────

  /// Build a draggable resize bar between two controls.
  /// [index] is the index of the control ABOVE (or LEFT of) this bar.
  /// [axis] is the main axis of the pane (vertical or horizontal).
  Widget _buildResizeBar(int index, Axis axis) {
    final isVert = axis == Axis.vertical;
    final isDraggingThis = _isResizeDragging && _resizeDragIndex == index;
    // Bar color: greenish-grey = default (no user override), grey = user-set size
    final meta = _getGutterMeta(index);
    final hasUserSize = meta?['preferred_size'] != null;
    final barColor = isDraggingThis
        ? Colors.blue
        : hasUserSize
            ? Colors.white38
            : const Color(0xFF5A6E5A); // greenish-grey for default
    return MouseRegion(
      cursor: isVert ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() {
        _isResizeHovering = true;
        _resizeHoverIndex = index;
      }),
      onExit: (_) => setState(() {
        if (_resizeHoverIndex == index) _isResizeHovering = false;
      }),
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == 2) {
            widget.control.triggerEvent(
                "resize_context", '{"index":$index}');
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () {
            widget.control.triggerEvent(
                "resize_reset", '{"index":$index}');
          },
          onVerticalDragStart: isVert ? (details) {
            _onResizeDragStart(index, axis, details.globalPosition.dy);
          } : null,
          onVerticalDragUpdate: isVert ? (details) {
            _onResizeDrag(index, details.delta.dy, axis, details.globalPosition.dy);
          } : null,
          onVerticalDragEnd: isVert ? (details) {
            _onResizeDragEnd(index);
          } : null,
          onHorizontalDragStart: !isVert ? (details) {
            _onResizeDragStart(index, axis, details.globalPosition.dx);
          } : null,
          onHorizontalDragUpdate: !isVert ? (details) {
            _onResizeDrag(index, details.delta.dx, axis, details.globalPosition.dx);
          } : null,
          onHorizontalDragEnd: !isVert ? (details) {
            _onResizeDragEnd(index);
          } : null,
          child: Container(
            width: isVert ? double.infinity : 10,
            height: isVert ? 10 : double.infinity,
            color: isDraggingThis ? Colors.blue.withValues(alpha: 0.15) : Colors.transparent,
            alignment: Alignment.center,
            child: Container(
              width: isVert ? 32 : 3,
              height: isVert ? 3 : 32,
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Resize drag state — ghost line feedback
  bool _isResizeHovering = false;
  int _resizeHoverIndex = -1;
  bool _isResizeDragging = false;
  double _resizeDragAccum = 0;
  double _resizeDragPosition = 0; // position of ghost line in content coords
  int _resizeDragIndex = -1;
  Axis _resizeDragAxis = Axis.vertical;

  void _onResizeDragStart(int index, Axis axis, double startPosition) {
    _resizeDragIndex = index;
    _resizeDragAccum = 0;
    _resizeDragPosition = startPosition;
    _resizeDragAxis = axis;
    setState(() => _isResizeDragging = true);
  }

  void _onResizeDrag(int index, double delta, Axis axis, double globalPos) {
    if (_resizeDragIndex != index) {
      _resizeDragIndex = index;
      _resizeDragAccum = 0;
    }
    _resizeDragAccum += delta;
    setState(() => _resizeDragPosition += delta);
  }

  void _onResizeDragEnd(int index) {
    setState(() => _isResizeDragging = false);
    if (_resizeDragAccum.abs() < 2) return;

    // Compute new preferred_size = current_size + drag_delta.
    // Current size comes from preferred_size if set, else the computed default.
    final meta = _getGutterMeta(index);
    final item = _parseSizingMeta(widget.control.children("controls").length);
    final curItem = index < item.length ? item[index] : null;

    final contentHeight = _layoutHeight - (_isHorizontal ? _idleWidth : 0);
    final contentWidth = _layoutWidth - (_isHorizontal ? 0 : _contentOffset.value + _paddingRight);

    // Current size: preferred_size > formula-computed > flex fallback
    final dragMeta = _getGutterMeta(index);
    final crossSize = _isHorizontal ? contentHeight : contentWidth;
    final formulaKey = _isHorizontal ? 'width_formula' : 'height_formula';
    final formulaSize = _evalSizeFormula(dragMeta, formulaKey, crossSize);

    double currentSize;
    if (curItem?.preferredSize != null) {
      currentSize = curItem!.preferredSize!;
    } else if (formulaSize != null) {
      currentSize = formulaSize;
    } else {
      final flex = curItem?.flex ?? 1.0;
      currentSize = _isHorizontal ? crossSize * flex : flex * 200;
    }

    final newSize = (currentSize + _resizeDragAccum).clamp(30.0, 10000.0);

    widget.control.triggerEvent(
        "resize_drag", '{"index":$index,"preferred_size":${newSize.toStringAsFixed(1)}}');
    _resizeDragAccum = 0;
    _resizeDragIndex = -1;
  }

  /// Wrap a control with a blue veil when it's the drag or hover target.
  Widget _wrapWithDragVeil(Widget child, int controlIndex) {
    final showVeil = (_isResizeDragging && _resizeDragIndex == controlIndex) ||
        (_isResizeHovering && _resizeHoverIndex == controlIndex);
    if (!showVeil) return child;
    final alpha = _isResizeDragging ? 0.08 : 0.04;
    final borderAlpha = _isResizeDragging ? 0.3 : 0.15;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: alpha),
                border: Border.all(
                    color: Colors.blue.withValues(alpha: borderAlpha), width: 1.5),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Ghost line indicator shown during resize drag.
  /// Returns null when not dragging. Uses global coords converted to local.
  Widget? _buildGhostLine() {
    if (!_isResizeDragging) return null;
    // Convert global drag position to local coordinates
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(
      _resizeDragAxis == Axis.vertical
          ? Offset(0, _resizeDragPosition)
          : Offset(_resizeDragPosition, 0),
    );
    if (_resizeDragAxis == Axis.vertical) {
      return Positioned(
        left: _contentOffset.value,
        right: _paddingRight,
        top: local.dy,
        height: 2,
        child: IgnorePointer(
          child: Container(color: Colors.blue.withValues(alpha: 0.8)),
        ),
      );
    } else {
      return Positioned(
        top: 0,
        bottom: _gutterWidth.value,
        left: local.dx,
        width: 2,
        child: IgnorePointer(
          child: Container(color: Colors.blue.withValues(alpha: 0.8)),
        ),
      );
    }
  }

  // ── Size formula evaluation ────────────────────────────────────────

  /// Measure rendered text width using Flutter's TextPainter.
  double _measureTextWidth(String text, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );
    tp.layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  /// Evaluate a size formula from gutter metadata.
  /// Returns pixel size, or null if no formula or evaluation fails.
  /// [formulaKey] is 'width_formula' or 'height_formula'.
  /// [meta] is the item's gutter metadata.
  /// [crossSize] is the cross-axis dimension of the pane.
  double? _evalSizeFormula(
      Map<String, dynamic>? meta, String formulaKey, double crossSize) {
    if (meta == null) return null;
    var formula = meta[formulaKey] as String?;
    if (formula == null || formula.isEmpty) return null;
    if (!MicroPythonService.isReady) return null;

    // Strip wrapping curly braces if present — formulas are plain Python
    // expressions (e.g., "cross_size * 2"), not f-strings.
    // Legacy metadata may have "{cross_size * 2}" which eval() treats as
    // a Python set literal, causing JSON serialization failure.
    if (formula.startsWith('{') && formula.endsWith('}')) {
      formula = formula.substring(1, formula.length - 1);
    }

    // Use full-precision values for smooth sizing. Cache key uses
    // rounded cross_size to avoid re-evaluating on sub-pixel drift,
    // but the actual formula gets precise values for smooth results.
    double _safe(double v) => v.isFinite ? v : 0.0;
    final context = <String, dynamic>{
      'pane_w': _safe(_layoutWidth),
      'pane_h': _safe(_layoutHeight),
      'cross_size': _safe(crossSize),
    };

    // If control provides display_value, measure text width
    final displayValue = meta['display_value'] as String?;
    if (displayValue != null) {
      final fontSize = (meta['font_size'] as num?)?.toDouble() ?? 14.0;
      context['text_w'] = _safe(_measureTextWidth(displayValue, fontSize));
      context['text_len'] = displayValue.length;
    }

    // Add any extra context from metadata (keys starting with 'ctx_')
    for (final key in meta.keys) {
      if (key.startsWith('ctx_')) {
        context[key.substring(4)] = meta[key];
      }
    }

    // Cache key rounds cross_size to nearest 4px to avoid re-evaluating
    // on every sub-pixel layout pass, while still updating when the
    // viewport changes meaningfully.
    final cacheKey = '$formulaKey|$formula|${(crossSize / 4).round()}'
        '|${displayValue?.hashCode ?? 0}';
    if (_formulaCache.containsKey(cacheKey)) {
      return _formulaCache[cacheKey] as double?;
    }

    try {
      final result = MicroPythonService.fmt(formula, context);
      if (result != null) {
        final value = double.tryParse(result);
        if (value != null && value > 0) {
          if (_formulaCache.length > 200) _formulaCache.clear();
          _formulaCache[cacheKey] = value;
          return value;
        }
      }
    } catch (e) {
      // Size formula error suppressed: $e (formula=$formula)
    }
    return null;
  }

  // ── Sizing engine ──────────────────────────────────────────────────

  /// Parse sizing metadata for all children.
  List<_ItemSizing> _parseSizingMeta(int childCount) {
    final items = <_ItemSizing>[];
    for (int i = 0; i < childCount; i++) {
      final meta = _getGutterMeta(i);
      items.add(_ItemSizing(
        preferredSize: (meta?['preferred_size'] as num?)?.toDouble(),
        absoluteSize: (meta?['absolute_size'] as num?)?.toDouble(),
        aspectRatio: (meta?['aspect_ratio'] as num?)?.toDouble(),
        flex: ((meta?['flex'] as num?)?.toDouble() ?? 1.0).clamp(0.1, 100.0),
        minSize: (meta?['min_size'] as num?)?.toDouble(),
        maxSize: (meta?['max_size'] as num?)?.toDouble(),
      ));
    }
    return items;
  }

  /// Resolve desired size for one item using priority-ordered intents.
  ///
  /// Priority (highest to lowest):
  ///   1. Natural — if the widget has no sizing hints, return null (no
  ///      SizedBox wrapper, widget picks its own height)
  ///   2. Absolute size — fixed pixels
  ///   3. Aspect ratio — height = crossSize / ar
  ///   4. Flex weight — height = flex * baseUnit
  ///
  /// In 'aspect' pane mode, aspect_ratio is promoted above absolute.
  double? _resolveDesiredSize(
      _ItemSizing item, double crossSize, double baseUnit) {
    // Check if this item has ANY sizing intent
    final hasAbsolute = item.absoluteSize != null;
    final hasAspect = item.aspectRatio != null && item.aspectRatio! > 0;

    // Natural: no sizing intents at all → return null (widget picks own size)
    // Flex always has a value (defaults to type-specific), so "natural" means
    // no absolute, no aspect, and flex is at its type default. We always
    // apply flex as the fallback, so natural controls still get proportional
    // sizing. True "no constraint" only if flex is exactly 0.
    // In practice, every control has a flex default, so this path gives
    // proportional sizing to everything.

    double? size;

    if (_sizingMode == 'natural') {
      // Natural mode: aspect ratio is top priority, otherwise natural size
      if (hasAspect) {
        size = crossSize / item.aspectRatio!;
      } else if (hasAbsolute) {
        size = item.absoluteSize!;
      } else {
        size = item.flex * baseUnit;
      }
    } else {
      // Gallery / Cram: standard priority order
      if (hasAbsolute) {
        size = item.absoluteSize!;
      } else if (hasAspect) {
        size = crossSize / item.aspectRatio!;
      } else {
        size = item.flex * baseUnit;
      }
    }

    // Apply hard min/max constraints
    if (size != null) {
      if (item.minSize != null) size = math.max(size, item.minSize!);
      if (item.maxSize != null) size = math.min(size, item.maxSize!);
      size = math.max(size, 20.0);
    }

    return size;
  }

  /// Compute item sizes along the main axis for vertical panes.
  ///
  /// Three modes:
  ///   'gallery' (default) — each item at its desired size, total can
  ///     exceed viewport → scrollable gallery.
  ///   'fit' — QP solver: minimize sum w_i*(h_i - desired_i)² subject
  ///     to sum(h_i) = available. Golden-ratio priority weights.
  ///   'aspect' — like gallery but aspect_ratio promoted to top priority.
  List<double?> _computeItemSizes(
      int childCount, double availableSize, double crossSize) {
    if (childCount == 0) return [];

    final items = _parseSizingMeta(childCount);
    const gap = 8.0;
    final totalGap = (childCount - 1) * gap;

    // Base unit for flex: 200px per 1.0 flex (viewport-independent)
    const baseUnit = 200.0;

    if (_sizingMode == 'fit') {
      return _solveCram(items, availableSize, crossSize, totalGap);
    }

    // Gallery or Aspect mode — each item independently resolved
    final sizes = <double?>[];
    for (final item in items) {
      sizes.add(_resolveDesiredSize(item, crossSize, baseUnit));
    }
    return sizes;
  }

  /// QP cram solver: fit all items into [availableSize] while minimizing
  /// weighted squared deviation from each item's desired size.
  ///
  /// Weights use golden ratio descent: top-priority intent gets φ^(N-1),
  /// next gets φ^(N-2), etc. Since all items go through the same
  /// priority resolution, the weight here reflects the item's resistance
  /// to being resized — derived from which intent type resolved.
  ///
  /// Analytical solution: h_i = desired_i + (S - sum(desired)) * (1/w_i) / sum(1/w_j)
  /// Then iteratively clamp violated min/max and redistribute.
  List<double?> _solveCram(List<_ItemSizing> items, double availableSize,
      double crossSize, double totalGap) {
    final n = items.length;
    final distributable = (availableSize - totalGap).clamp(0.0, double.infinity);

    // For cram mode, base unit = distribute evenly as starting point
    final flexTotal = items.fold(0.0, (sum, item) => sum + item.flex);
    final cramBaseUnit = distributable / math.max(flexTotal, 0.1);

    // Resolve desired sizes — null becomes flex-based in cram mode
    final desired = <double>[];
    final weights = <double>[];
    const phi = 1.618033988749895; // golden ratio

    for (final item in items) {
      final d = _resolveDesiredSize(item, crossSize, cramBaseUnit);
      desired.add(d ?? (item.flex * cramBaseUnit));

      // Weight by intent type: absolute/aspect resist more than flex
      if (item.absoluteSize != null) {
        weights.add(phi * phi * phi); // ~4.24 — strongest resistance
      } else if (item.aspectRatio != null && item.aspectRatio! > 0) {
        weights.add(phi * phi);       // ~2.62
      } else {
        weights.add(1.0);             // flex — most flexible
      }
    }

    // Iterative clamp-and-redistribute QP solve
    final sizes = List<double>.from(desired);
    final frozen = List<bool>.filled(n, false);

    for (int iter = 0; iter < n + 1; iter++) {
      // Compute deficit/surplus among unfrozen items
      double frozenSum = 0;
      double unfrozenDesiredSum = 0;
      double invWeightSum = 0;

      for (int i = 0; i < n; i++) {
        if (frozen[i]) {
          frozenSum += sizes[i];
        } else {
          unfrozenDesiredSum += desired[i];
          invWeightSum += 1.0 / weights[i];
        }
      }

      final unfrozenTarget = distributable - frozenSum;
      final deficit = unfrozenTarget - unfrozenDesiredSum;

      // Distribute deficit proportional to 1/w_i (lower weight = absorbs more)
      bool anyClamped = false;
      for (int i = 0; i < n; i++) {
        if (frozen[i]) continue;
        sizes[i] = desired[i] + deficit * (1.0 / weights[i]) / invWeightSum;

        // Clamp and freeze if violated
        final minS = items[i].minSize ?? 20.0;
        final maxS = items[i].maxSize;
        if (sizes[i] < minS) {
          sizes[i] = minS;
          frozen[i] = true;
          anyClamped = true;
        } else if (maxS != null && sizes[i] > maxS) {
          sizes[i] = maxS;
          frozen[i] = true;
          anyClamped = true;
        }
      }

      if (!anyClamped) break;
    }

    // Floor at 20px
    return sizes.map<double?>((s) => math.max(s, 20.0)).toList();
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final childControls = widget.control.children("controls");

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
      content = LayoutBuilder(
        builder: (context, constraints) {
          _layoutHeight = constraints.maxHeight;
          _layoutWidth = constraints.maxWidth;
          return MouseRegion(
            onHover: _onHover,
            onExit: _onExit,
            child: _buildVerticalContent(childControls,
                constraints.maxHeight, constraints.maxWidth),
          );
        },
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

  /// Vertical layout: content scrolls vertically, gallery gutter on left.
  Widget _buildVerticalContent(
      List<Control> childControls, double availableHeight,
      double availableWidth) {
    final arrowBtnSize = _arrowSize + 16;
    final arrowLeft = (_hoverWidth - arrowBtnSize) / 2;
    // print('[PaneWidget] vert mode=$_sizingMode children=${childControls.length}');

    // Build content area based on sizing mode
    Widget contentArea;
    if (_sizingMode == 'fit') {
      // Cram mode: Column with Flexible children — all items fit viewport.
      // Items with absolute_size get fixed height; others get Flexible.
      final items = _parseSizingMeta(childControls.length);
      final contentWidth = availableWidth - _contentOffset.value - _paddingRight;
      final cramChildren = <Widget>[];

      for (int i = 0; i < childControls.length; i++) {
        final item = items[i];
        Widget child = _wrapWithDragVeil(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox.expand(
              child: ControlWidget(control: childControls[i]),
            ),
          ),
          i,
        );

        // Apply min/max constraints
        if (item.minSize != null || item.maxSize != null) {
          child = ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: item.minSize ?? 0,
              maxHeight: item.maxSize ?? double.infinity,
            ),
            child: child,
          );
        }

        // In Fit mode, derive flex from desired height via formula.
        final meta = _getGutterMeta(i);
        final formulaH = _evalSizeFormula(meta, 'height_formula', contentWidth);
        final desiredH = item.preferredSize
            ?? formulaH
            ?? item.flex * 200;
        final flexInt = (desiredH * 10).round().clamp(1, 100000);
        {
          cramChildren.add(Flexible(
            key: ValueKey(childControls[i].id),
            flex: flexInt,
            child: child,
          ));
        }
      }

      contentArea = Padding(
        padding: EdgeInsets.only(
          left: _contentOffset.value,
          right: _paddingRight,
          top: _paddingTop,
          bottom: _paddingBottom,
        ),
        child: Column(children: () {
          final withBars = <Widget>[];
          for (int i = 0; i < cramChildren.length; i++) {
            if (i > 0) {
              withBars.add(_buildResizeBar(i - 1, Axis.vertical));
            }
            withBars.add(cramChildren[i]);
          }
          if (cramChildren.isNotEmpty) {
            withBars.add(_buildResizeBar(cramChildren.length - 1, Axis.vertical));
          }
          return withBars;
        }()),
      );
    } else if (_sizingMode == 'natural') {
      // Natural: respect aspect_ratio > absolute_size > natural height. Scrollable.
      final items = _parseSizingMeta(childControls.length);
      final contentWidth = availableWidth - _contentOffset.value - _paddingRight;

      // Interleaved: control, bar, control, bar, ..., control, trailing_bar
      final totalItems = math.max(0, childControls.length * 2);
      contentArea = ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(
          left: _contentOffset.value,
          right: _paddingRight,
          top: _paddingTop,
          bottom: _paddingBottom,
        ),
        itemCount: totalItems,
        cacheExtent: 500,
        itemBuilder: (context, listIndex) {
          // Odd indices are resize bars (including trailing after last control)
          if (listIndex.isOdd) {
            final ctrlIndex = listIndex ~/ 2;
            return _buildResizeBar(ctrlIndex, Axis.vertical);
          }
          final ctrlIndex = listIndex ~/ 2;
          if (ctrlIndex >= childControls.length) {
            return const SizedBox.shrink();
          }
          final item = items[ctrlIndex];
          Widget child = ControlWidget(control: childControls[ctrlIndex]);

          // Height: preferred_size (user drag) > formula > intrinsic
          final meta = _getGutterMeta(ctrlIndex);
          final formulaH = _evalSizeFormula(meta, 'height_formula', contentWidth);
          final h = item.preferredSize ?? formulaH;
          if (h != null) {
            child = SizedBox(height: h, width: double.infinity, child: child);
          }
          // else: intrinsic height (no SizedBox)

          // Min/max constraints
          if (item.minSize != null || item.maxSize != null) {
            child = ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: item.minSize ?? 0,
                maxHeight: item.maxSize ?? double.infinity,
              ),
              child: child,
            );
          }

          return _wrapWithDragVeil(
            Padding(
              key: ValueKey(childControls[ctrlIndex].id),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: child,
            ),
            ctrlIndex,
          );
        },
      );
    } else {
      // Gallery mode: ListView with natural heights — scrollable gallery.
      contentArea = ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(
          left: _contentOffset.value,
          right: _paddingRight,
          top: _paddingTop,
          bottom: _paddingBottom,
        ),
        itemCount: childControls.length,
        cacheExtent: 500,
        itemBuilder: (context, index) {
          return Padding(
            key: ValueKey(childControls[index].id),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ControlWidget(control: childControls[index]),
          );
        },
      );
    }

    final ghostLine = _buildGhostLine();
    return Stack(
      children: [
        // Content area (full width, padded left for gutter)
        Positioned.fill(child: contentArea),

        // Ghost line during resize drag
        if (ghostLine != null) ghostLine,

        // Gutter gallery strip (overlays left edge) with scroll handlers
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _gutterWidth.value,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              if (_scrollController.hasClients) {
                final pos = _scrollController.position;
                final newOffset =
                    (_scrollController.offset - details.delta.dy)
                        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
                _scrollController.jumpTo(newOffset);
              }
            },
            onVerticalDragEnd: (details) {
              if (!_scrollController.hasClients) return;
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 50) return;
              final pos = _scrollController.position;
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
              child: _buildGutterGalleryStrip(
                  Axis.vertical, childControls),
            ),
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

  /// Horizontal layout: gallery = page-through, cram = all items side by side.
  Widget _buildHorizontalContent(List<Control> childControls) {
    // print('[PaneWidget] horiz mode=$_sizingMode children=${childControls.length}');

    // Build content area based on sizing mode
    Widget contentArea;
    if (_sizingMode == 'fit') {
      // Cram: all items side by side, proportional widths.
      // Items with absolute_size get fixed width; others get Flexible.
      final items = _parseSizingMeta(childControls.length);
      final contentHeight = _layoutHeight - _idleWidth;
      final children = <Widget>[];

      for (int i = 0; i < childControls.length; i++) {
        final item = items[i];
        Widget child = _wrapWithDragVeil(
          Padding(
            padding: EdgeInsets.all(_paddingTop),
            child: SizedBox.expand(
              child: ControlWidget(control: childControls[i]),
            ),
          ),
          i,
        );

        // Apply min/max constraints
        if (item.minSize != null || item.maxSize != null) {
          child = ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: item.minSize ?? 0,
              maxWidth: item.maxSize ?? double.infinity,
            ),
            child: child,
          );
        }

        // In Fit mode, ALL items are Flexible. Derive flex from desired width.
        final meta = _getGutterMeta(i);
        final formulaW = _evalSizeFormula(meta, 'width_formula', contentHeight);
        final desiredW = item.preferredSize
            ?? formulaW
            ?? contentHeight * item.flex;
        {
          final flexInt = (desiredW * 10).round().clamp(1, 100000);
          children.add(Flexible(
            key: ValueKey(childControls[i].id),
            flex: flexInt,
            child: child,
          ));
        }
      }
      // Interleave resize bars + trailing bar for last item
      final withBars = <Widget>[];
      for (int i = 0; i < children.length; i++) {
        if (i > 0) {
          withBars.add(_buildResizeBar(i - 1, Axis.horizontal));
        }
        withBars.add(children[i]);
      }
      // Trailing bar for the last control
      if (children.isNotEmpty) {
        withBars.add(_buildResizeBar(children.length - 1, Axis.horizontal));
      }
      contentArea = Row(children: withBars);
    } else if (_sizingMode == 'natural') {
      // Natural: each item at its preferred size. Aspect ratio > absolute > natural.
      // Scrollable if total exceeds viewport.
      final items = _parseSizingMeta(childControls.length);
      // Use idle gutter width (not animated value) for stable cross_size.
      // Animated _gutterWidth.value oscillates during hover, causing formula
      // results to change each frame → infinite layout loop.
      final contentHeight = _layoutHeight - _idleWidth;
      final natChildren = <Widget>[];

      for (int i = 0; i < childControls.length; i++) {
        final item = items[i];
        Widget child = _wrapWithDragVeil(
          Padding(
            padding: EdgeInsets.all(_paddingTop),
            child: ControlWidget(control: childControls[i]),
          ),
          i,
        );

        // Width: preferred_size (user drag) > formula-computed > fallback.
        final meta = _getGutterMeta(i);
        final formulaW = _evalSizeFormula(meta, 'width_formula', contentHeight);
        final w = item.preferredSize ?? formulaW ?? contentHeight * item.flex;
        child = SizedBox(
          key: ValueKey(childControls[i].id),
          width: w,
          child: child,
        );

        // Apply min/max
        if (item.minSize != null || item.maxSize != null) {
          child = ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: item.minSize ?? 0,
              maxWidth: item.maxSize ?? double.infinity,
            ),
            child: child,
          );
        }
        natChildren.add(child);
      }

      // Interleave resize bars + trailing bar
      final withBars = <Widget>[];
      for (int i = 0; i < natChildren.length; i++) {
        if (i > 0) {
          withBars.add(_buildResizeBar(i - 1, Axis.horizontal));
        }
        withBars.add(natChildren[i]);
      }
      if (natChildren.isNotEmpty) {
        withBars.add(_buildResizeBar(natChildren.length - 1, Axis.horizontal));
      }
      // Buffer lane so trailing bar is accessible and draggable rightward
      withBars.add(SizedBox(width: _layoutWidth * 0.3));
      contentArea = SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Row(children: withBars),
      );
    } else {
      // Gallery: page-through with full viewport width per item
      contentArea = SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(
          children: childControls
              .map((child) => SizedBox(
                    key: ValueKey(child.id),
                    width: _layoutWidth,
                    child: Padding(
                      padding: EdgeInsets.all(_paddingTop),
                      child: ControlWidget(control: child),
                    ),
                  ))
              .toList(),
        ),
      );
    }

    final ghostLine = _buildGhostLine();
    return Stack(
      children: [
        // Main content area above gutter
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: _gutterWidth.value,
          child: contentArea,
        ),

        // Ghost line during resize drag
        if (ghostLine != null) ghostLine,

        // Gutter gallery strip at bottom with drag + wheel handlers
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: _gutterWidth.value,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              if (_scrollController.hasClients) {
                final pos = _scrollController.position;
                final newOffset =
                    (_scrollController.offset - details.delta.dx)
                        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
                _scrollController.jumpTo(newOffset);
              }
            },
            onHorizontalDragEnd: (details) {
              if (!_scrollController.hasClients || _layoutWidth <= 0) return;
              final velocity = details.primaryVelocity ?? 0;
              if (_sizingMode == 'gallery') {
                // Gallery: snap to nearest item boundary (page-through)
                int targetIndex = _activeIndex;
                if (velocity < -200) {
                  targetIndex = (_activeIndex + 1);
                } else if (velocity > 200) {
                  targetIndex = (_activeIndex - 1);
                } else {
                  targetIndex = (_scrollController.offset / _layoutWidth).round();
                }
                final childCount = widget.control.children("controls").length;
                targetIndex = targetIndex.clamp(0, math.max(0, childCount - 1));
                _scrollController.animateTo(
                  targetIndex * _layoutWidth,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              } else {
                // Natural/Fit: soft-close momentum — coast then decelerate
                if (velocity.abs() < 50) return;
                final pos = _scrollController.position;
                final target = (_scrollController.offset - velocity * 0.4)
                    .clamp(pos.minScrollExtent, pos.maxScrollExtent);
                _scrollController.animateTo(
                  target,
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                );
              }
            },
            child: Listener(
              onPointerSignal: (event) {
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
              child: _buildGutterGalleryStrip(
                  Axis.horizontal, childControls),
            ),
          ),
        ),
      ],
    );
  }

  // ── Gallery strip (unified for both orientations) ──────────────────

  /// Build the gallery strip with positioned thumbnails.
  /// [axis] determines layout direction (Y for vertical, X for horizontal).
  Widget _buildGutterGalleryStrip(Axis axis, List<Control> childControls) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutterLength = axis == Axis.vertical
            ? constraints.maxHeight
            : constraints.maxWidth;
        final crossSize = axis == Axis.vertical
            ? constraints.maxWidth
            : constraints.maxHeight;

        final arrowReserve = _isExpanded ? _arrowSize + 24.0 : 8.0;
        final thumbSize = (crossSize * 0.9).clamp(12.0, 48.0);

        // Compute fractional current index for smooth gallery animation
        final childCount = childControls.length;
        double currentIndex;
        if (_isHorizontal &&
            _layoutWidth > 0 &&
            _scrollController.hasClients) {
          currentIndex = (_scrollController.position.pixels / _layoutWidth)
              .clamp(0.0, math.max(0, childCount - 1).toDouble());
        } else if (childCount > 1 &&
            _scrollController.hasClients &&
            _scrollController.position.maxScrollExtent > 0) {
          currentIndex = _computeScrollFraction() * (childCount - 1);
        } else {
          currentIndex = 0;
        }

        final positions = _computeGalleryPositions(
          count: childCount,
          currentIndex: currentIndex,
          gutterLength: gutterLength,
          arrowReserve: arrowReserve,
          thumbSize: thumbSize,
        );

        // Sort by z-order: lowest first = painted behind
        positions.sort((a, b) => a.zOrder.compareTo(b.zOrder));

        // Mode pill label and color
        final modeLabel = _modeLabels[_sizingMode] ?? 'N';
        final modeColor = _modeColors[_sizingMode] ?? const Color(0xFF4CAF50);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Gutter background — double-tap cycles mode, right-click context
            Positioned.fill(
              child: Listener(
                onPointerDown: (event) {
                  if (event.buttons == 2) {
                    widget.control.triggerEvent(
                        "gutter_context", '{"index":-1}');
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: _cycleMode,
                  child: Container(
                    color: _gutterBgColor.value ?? Colors.transparent,
                  ),
                ),
              ),
            ),

            // Gallery thumbnails
            for (final pos in positions)
              if (axis == Axis.vertical)
                Positioned(
                  left: 0,
                  right: 0,
                  top: pos.offset,
                  height: thumbSize,
                  child: _buildGalleryThumbnail(pos, crossSize, thumbSize),
                )
              else
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: pos.offset,
                  width: thumbSize,
                  child: _buildGalleryThumbnail(pos, thumbSize, crossSize),
                ),

            // Mode pill indicator — corner of gutter
            // Mode pill — top corner of gutter (painted after arrows, so on top)
            if (_isExpanded)
              Positioned(
                left: axis == Axis.vertical ? 2 : null,
                right: axis == Axis.horizontal ? 4 : null,
                top: axis == Axis.vertical ? 4 : 2,
                child: GestureDetector(
                  onTap: _cycleMode,
                  child: Tooltip(
                    message: '${_sizingMode[0].toUpperCase()}${_sizingMode.substring(1)} mode\nTap pill or double-tap gutter to cycle',
                    waitDuration: const Duration(seconds: 2),
                    child: Container(
                      width: 18,
                      height: 14,
                      decoration: BoxDecoration(
                        color: modeColor.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        modeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Single gallery thumbnail with tap, right-click, and hover preview.
  ///
  /// Right-click uses Listener (raw pointer events) instead of
  /// GestureDetector.onSecondaryTapUp to avoid gesture arena conflicts
  /// with the outer drag-handling GestureDetector.
  Widget _buildGalleryThumbnail(
      _ThumbPosition pos, double width, double height) {
    final meta = _getGutterMeta(pos.index);
    final thumbData =
        (meta?['gutter_thumbnail'] ?? meta?['gutter_icon']) as String?;
    final indicatorColor = _resolveIndicatorColor(meta);
    final isCurrent = pos.index == _activeIndex;

    return Listener(
      // Right-click: raw pointer event bypasses gesture arena
      onPointerDown: (event) {
        if (event.buttons == 2) {
          widget.control.triggerEvent(
              "gutter_context", '{"index":${pos.index}}');
        }
      },
      child: GestureDetector(
        onTap: () {
          _scrollToIndex(pos.index);
          widget.control.triggerEvent("gutter_tap", {"index": pos.index});
        },
        // Long-press as fallback context menu trigger
        onLongPress: () {
          widget.control.triggerEvent(
              "gutter_context", '{"index":${pos.index}}');
        },
        child: MouseRegion(
          onEnter: (event) =>
              _startHoverPreview(pos.index, event.position),
          onExit: (_) => _cancelHoverPreview(),
          child: Opacity(
            opacity: isCurrent ? 1.0 : _iconOpacity.value.clamp(0.0, 0.7),
            child: Transform.scale(
              scale: pos.scale,
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: isCurrent
                      ? Border.all(color: Colors.white54, width: 1.5)
                      : null,
                ),
                child: Stack(
                  children: [
                    // Thumbnail image
                    if (thumbData != null)
                      Center(
                        child: GutterRow.buildIconFromBase64(
                          thumbData,
                          math.min(width, height) - 4,
                        ),
                      ),
                    // Color accent dot at bottom center
                    if (indicatorColor != null)
                      Positioned(
                        bottom: 1,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            width: isCurrent ? 8 : 5,
                            height: 2,
                            decoration: BoxDecoration(
                              color: indicatorColor.withValues(
                                  alpha: isCurrent ? 0.9 : 0.5),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                      ),
                    // Dot indicator when no thumbnail
                    if (thumbData == null)
                      Center(
                        child: Container(
                          width: isCurrent ? 6 : 3,
                          height: isCurrent ? 6 : 3,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: indicatorColor ?? Colors.white30,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Hover preview ──────────────────────────────────────────────────

  void _startHoverPreview(int index, Offset globalPos) {
    _cancelHoverPreview();
    _hoverTimer = Timer(const Duration(seconds: 1), () {
      _showPreview(index, globalPos);
    });
  }

  void _cancelHoverPreview() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    _previewOverlay?.remove();
    _previewOverlay = null;
  }

  void _showPreview(int index, Offset globalPos) {
    final meta = _getGutterMeta(index);
    final thumbData =
        (meta?['gutter_thumbnail'] ?? meta?['gutter_icon']) as String?;
    if (thumbData == null || !mounted) return;

    double left, top;
    if (_isHorizontal) {
      left = globalPos.dx - 80;
      top = globalPos.dy - 140;
    } else {
      left = globalPos.dx + 20;
      top = globalPos.dy - 60;
    }

    _previewOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        child: IgnorePointer(
          child: Container(
            width: 160,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Opacity(
                opacity: 0.8,
                child: GutterRow.buildIconFromBase64(thumbData, 152),
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_previewOverlay!);
  }

  // ── Arrow button ───────────────────────────────────────────────────

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

// ── Painters ──────────────────────────────────────────────────────────

/// Radial indicator dot painter for gallery thumbnails.
class _IndicatorDotPainter extends CustomPainter {
  final Color color;
  final double opacity;

  _IndicatorDotPainter({required this.color, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity < 0.01) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.4;
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
