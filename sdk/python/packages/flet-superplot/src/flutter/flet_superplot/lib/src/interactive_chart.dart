import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'models/axis_model.dart';
import 'models/series_model.dart';
import 'painters/chart_painter.dart';

/// Scale gesture recognizer that eagerly claims trackpad (pan/zoom) events,
/// preventing parent Scrollable/ListView from competing for them.
class _EagerScaleGestureRecognizer extends ScaleGestureRecognizer {
  _EagerScaleGestureRecognizer({super.supportedDevices});

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    super.addAllowedPointerPanZoom(event);
    // Immediately win the gesture arena for trackpad events.
    // This prevents parent ListView/Scrollable from stealing scroll.
    resolve(GestureDisposition.accepted);
  }
}

/// Interactive chart widget with mouse wheel zoom, pinch-to-zoom,
/// drag-to-pan, and double-tap to reset. Wraps [ChartPainter] with
/// gesture handling.
///
/// Uses an eager [ScaleGestureRecognizer] that claims trackpad events
/// immediately, preventing parent ScrollView/ListView from competing.
/// Also uses [Listener.onPointerSignal] with [PointerSignalResolver]
/// to claim mouse wheel events before parent Scrollable.
class InteractiveChart extends StatefulWidget {
  final AxisModel? xAxis;
  final AxisModel? yAxis;
  final AxisModel? yAxis2; // Secondary Y axis (left side, for dual-axis charts)
  final List<SeriesModel> series;
  final DataBufferStore dataBuffers;
  final Color backgroundColor;
  final bool showMajorGridLines;
  final bool showMinorGridLines;
  final Color majorGridLineColor;
  final Color minorGridLineColor;

  /// Chart annotations (horizontal/vertical lines, text, boxes).
  final List<Map<String, dynamic>> annotations;

  /// Mutable render state for draggable annotations + PaletteProvider.
  final Map<String, dynamic> renderState;

  /// Callback fired when renderState is mutated during drag.
  final VoidCallback? onRenderStateChanged;

  /// Callback fired when visible range changes (on gesture end).
  final void Function(double xMin, double xMax, double yMin, double yMax)?
      onVisibleRangeChanged;

  const InteractiveChart({
    super.key,
    this.xAxis,
    this.yAxis,
    this.yAxis2,
    required this.series,
    required this.dataBuffers,
    required this.backgroundColor,
    required this.showMajorGridLines,
    required this.showMinorGridLines,
    required this.majorGridLineColor,
    required this.minorGridLineColor,
    this.annotations = const [],
    this.renderState = const {},
    this.onRenderStateChanged,
    this.onVisibleRangeChanged,
  });

  @override
  State<InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<InteractiveChart>
    with TickerProviderStateMixin {
  // Mutable visible ranges. Null = use axis config / auto-range.
  double? _xVisibleMin;
  double? _xVisibleMax;
  double? _yVisibleMin;
  double? _yVisibleMax;

  // Whether the user has explicitly zoomed/panned (vs default view)
  bool _userHasZoomed = false;

  // Gesture state
  bool _isGesturing = false;
  Offset? _scaleStartFocalPoint;
  double? _scaleStartXMin;
  double? _scaleStartXMax;
  double? _scaleStartYMin;
  double? _scaleStartYMax;
  _HitRegion _gestureRegion = _HitRegion.chart;

  // Trackpad detection: on macOS desktop, trackpad scroll generates
  // PointerPanZoomUpdateEvent (not PointerScrollEvent). ScaleGestureRecognizer
  // treats this as pan (scale=1.0). We detect trackpad origin and convert
  // the vertical scroll delta to zoom instead.
  bool _isTrackpadGesture = false;
  // Per-frame tracking for incremental trackpad zoom (avoids cumulative
  // acceleration that makes zoom feel abrupt).
  Offset? _lastTrackpadFocalPoint;

  // Momentum animation for trackpad zoom deceleration.
  // On web the browser provides inertia; on desktop we simulate it.
  Ticker? _momentumTicker;
  double _momentumVelocity = 0;
  Duration? _lastTickTime;
  Offset? _momentumCursor; // zoom center during momentum

  // Debounce timer for scroll gesture end
  Timer? _scrollEndTimer;

  // Last known widget size (from LayoutBuilder)
  Size _lastSize = Size.zero;

  // Legend state
  final Set<int> _hiddenSeriesIndices = {};
  final List<Rect> _legendHitRects = [];

  // Hover state for crosshair
  Offset? _hoverPosition;

  // Undo/redo button hit rects (populated by ChartPainter)
  final List<Rect> _undoRedoHitRects = [];

  // Right-click detection
  bool _isSecondaryButton = false;

  // Draggable annotation drag state
  String? _draggingAnnotationId;
  String? _draggingAnnotationType; // 'draggable_hline' or 'draggable_vline'

  // Rubber band zoom state (Shift+drag)
  bool _isRubberBand = false;
  Offset? _rubberBandStart;
  Offset? _rubberBandEnd;

  // Zoom history undo/redo stacks
  static const int _maxHistoryDepth = 20;
  final List<_ViewportState> _undoStack = [];
  final List<_ViewportState> _redoStack = [];

  /// Push current viewport onto undo stack (call before changing ranges).
  void _pushViewportUndo() {
    if (_xVisibleMin == null) return;
    _undoStack.add(_ViewportState(
      _xVisibleMin!, _xVisibleMax!, _yVisibleMin!, _yVisibleMax!));
    if (_undoStack.length > _maxHistoryDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void _undoZoom() {
    if (_undoStack.isEmpty) return;
    // Save current state for redo
    if (_xVisibleMin != null) {
      _redoStack.add(_ViewportState(
        _xVisibleMin!, _xVisibleMax!, _yVisibleMin!, _yVisibleMax!));
    }
    final prev = _undoStack.removeLast();
    setState(() {
      _xVisibleMin = prev.xMin;
      _xVisibleMax = prev.xMax;
      _yVisibleMin = prev.yMin;
      _yVisibleMax = prev.yMax;
      _userHasZoomed = true;
    });
    _notifyRangeChanged();
  }

  void _redoZoom() {
    if (_redoStack.isEmpty) return;
    // Save current state for undo
    if (_xVisibleMin != null) {
      _undoStack.add(_ViewportState(
        _xVisibleMin!, _xVisibleMax!, _yVisibleMin!, _yVisibleMax!));
    }
    final next = _redoStack.removeLast();
    setState(() {
      _xVisibleMin = next.xMin;
      _xVisibleMax = next.xMax;
      _yVisibleMin = next.yMin;
      _yVisibleMax = next.yMax;
      _userHasZoomed = true;
    });
    _notifyRangeChanged();
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      BrowserContextMenu.disableContextMenu();
    }
  }

  @override
  void dispose() {
    _scrollEndTimer?.cancel();
    _stopMomentum();
    if (kIsWeb) {
      BrowserContextMenu.enableContextMenu();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(InteractiveChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If parent pushes new axis config while user hasn't zoomed, respect it
    if (!_userHasZoomed) {
      ChartPainter.resetAutoRange();
      _xVisibleMin = null;
      _xVisibleMax = null;
      _yVisibleMin = null;
      _yVisibleMax = null;
    }
  }

  /// Ensure we have explicit mutable ranges (called on first interaction).
  ///
  /// Adopts the ranges the painter last computed (including stacking, waterfall,
  /// hidden-series filtering, etc.) so the first zoom frame is an identity
  /// transform — no visual jump. Falls back to recomputing from data only if
  /// the painter hasn't painted yet.
  void _ensureExplicitRanges() {
    if (_xVisibleMin != null) return;

    // Prefer the painter's cached auto-range — it includes stacking
    // accumulation, waterfall cumulative, and hidden-series filtering
    // that we cannot easily replicate here.
    if (ChartPainter.lastAutoXMin != null) {
      _xVisibleMin = ChartPainter.lastAutoXMin;
      _xVisibleMax = ChartPainter.lastAutoXMax;
      _yVisibleMin = ChartPainter.lastAutoYMin;
      _yVisibleMax = ChartPainter.lastAutoYMax;
      _userHasZoomed = true;
      return;
    }

    // Fallback: compute from data (painter hasn't painted yet)
    final xAxis = widget.xAxis;
    final yAxis = widget.yAxis;

    double xMin = xAxis?.visibleRangeMin ?? double.infinity;
    double xMax = xAxis?.visibleRangeMax ?? double.negativeInfinity;
    double yMin = yAxis?.visibleRangeMin ?? double.infinity;
    double yMax = yAxis?.visibleRangeMax ?? double.negativeInfinity;

    final xAutoRange = xAxis?.autoRange != 'never';
    final yAutoRange = yAxis?.autoRange != 'never';

    if (xAutoRange || yAutoRange) {
      for (final s in widget.series) {
        if (s.usesNamedBuffers) {
          if (xAutoRange && s.xCol != null) {
            final (dataXMin, dataXMax) = widget.dataBuffers.range(s.xCol!);
            if (dataXMin < xMin) xMin = dataXMin;
            if (dataXMax > xMax) xMax = dataXMax;
          }
          if (yAutoRange) {
            final (dataYMin, dataYMax) = s.yRangeFromBuffers(widget.dataBuffers);
            if (dataYMin < yMin) yMin = dataYMin;
            if (dataYMax > yMax) yMax = dataYMax;
          }
        } else if (s.data != null && s.data!.isNotEmpty) {
          if (xAutoRange) {
            final (dataXMin, dataXMax) = s.data!.xRange;
            if (dataXMin < xMin) xMin = dataXMin;
            if (dataXMax > xMax) xMax = dataXMax;
          }
          if (yAutoRange) {
            final (dataYMin, dataYMax) = s.data!.yRange;
            if (dataYMin < yMin) yMin = dataYMin;
            if (dataYMax > yMax) yMax = dataYMax;
          }
        }
      }
    }

    if (xMin.isFinite && xMax.isFinite) {
      if (_xIsLog && xMin > 0 && xMax > xMin) {
        xMin = xMin / math.pow(_xLogBase, xAxis?.growByMin ?? 0.1);
        xMax = xMax * math.pow(_xLogBase, xAxis?.growByMax ?? 0.1);
      } else {
        final xRange = xMax - xMin;
        if (xRange > 0) {
          xMin -= xRange * (xAxis?.growByMin ?? 0.1);
          xMax += xRange * (xAxis?.growByMax ?? 0.1);
        }
      }
    } else {
      xMin = _xIsLog ? 0.1 : 0;
      xMax = _xIsLog ? 10 : 1;
    }

    if (yMin.isFinite && yMax.isFinite) {
      if (_yIsLog && yMin > 0 && yMax > yMin) {
        yMin = yMin / math.pow(_yLogBase, yAxis?.growByMin ?? 0.1);
        yMax = yMax * math.pow(_yLogBase, yAxis?.growByMax ?? 0.1);
      } else {
        final yRange = yMax - yMin;
        if (yRange > 0) {
          yMin -= yRange * (yAxis?.growByMin ?? 0.1);
          yMax += yRange * (yAxis?.growByMax ?? 0.1);
        }
      }
    } else {
      yMin = _yIsLog ? 0.1 : 0;
      yMax = _yIsLog ? 10 : 1;
    }

    _xVisibleMin = xMin;
    _xVisibleMax = xMax;
    _yVisibleMin = yMin;
    _yVisibleMax = yMax;
    _userHasZoomed = true;
  }

  // Log axis helpers for coordinate conversion
  bool get _xIsLog => widget.xAxis?.isLogarithmic == true;
  bool get _yIsLog => widget.yAxis?.isLogarithmic == true;
  double get _xLogBase => widget.xAxis?.logarithmicBase ?? 10.0;
  double get _yLogBase => widget.yAxis?.logarithmicBase ?? 10.0;

  double _screenToDataX(double screenX, Rect plotArea, double xMin, double xMax) {
    return ChartPainter.screenToDataX(screenX, plotArea, xMin, xMax,
        isLogarithmic: _xIsLog, logarithmicBase: _xLogBase);
  }

  double _screenToDataY(double screenY, Rect plotArea, double yMin, double yMax) {
    return ChartPainter.screenToDataY(screenY, plotArea, yMin, yMax,
        isLogarithmic: _yIsLog, logarithmicBase: _yLogBase);
  }

  /// Get the plot area for coordinate conversion during gestures.
  /// Uses the same simple inset-based mapping as ChartPainter.
  Rect _getPlotArea() {
    if (_xVisibleMin == null || _lastSize == Size.zero) return Rect.zero;
    return ChartPainter.computePlotArea(size: _lastSize, hasLeftAxis: widget.yAxis2 != null);
  }

  /// Determine which region a local position falls in.
  _HitRegion _hitTest(Offset localPosition) {
    final chartRight = _lastSize.width - ChartPainter.rightAxisWidth;
    final chartBottom = _lastSize.height - ChartPainter.bottomAxisHeight;

    if (localPosition.dx < chartRight && localPosition.dy < chartBottom) {
      return _HitRegion.chart;
    }
    if (localPosition.dx < chartRight && localPosition.dy >= chartBottom) {
      return _HitRegion.xAxis;
    }
    if (localPosition.dx >= chartRight && localPosition.dy < chartBottom) {
      return _HitRegion.yAxis;
    }
    return _HitRegion.none;
  }

  // ---------------------------------------------------------------------------
  // Mouse wheel zoom — uses PointerSignalResolver to claim events before
  // parent Scrollable/ListView. Innermost widget registers first and wins.
  // ---------------------------------------------------------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final region = _hitTest(event.localPosition);
      if (region == _HitRegion.none) return;

      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (resolvedEvent) => _handleScrollZoom(
            resolvedEvent as PointerScrollEvent, region),
      );
    }
  }

  void _handleScrollZoom(PointerScrollEvent event, _HitRegion region) {
    _ensureExplicitRanges();
    final plotArea = _getPlotArea();
    if (plotArea == Rect.zero) return;

    // Push undo on first scroll event of a sequence (not during momentum)
    if (!_isGesturing) {
      _pushViewportUndo();
    }

    final zoomAmount = event.scrollDelta.dy / 1500.0;
    if (zoomAmount.abs() < 1e-6) return;
    final zoomFactor = 1.0 + zoomAmount.clamp(-0.15, 0.15);

    final cursorX = _screenToDataX(
        event.localPosition.dx.clamp(0, plotArea.right),
        plotArea, _xVisibleMin!, _xVisibleMax!);
    final cursorY = _screenToDataY(
        event.localPosition.dy.clamp(0, plotArea.bottom),
        plotArea, _yVisibleMin!, _yVisibleMax!);

    double newXMin = _xVisibleMin!;
    double newXMax = _xVisibleMax!;
    double newYMin = _yVisibleMin!;
    double newYMax = _yVisibleMax!;

    if (region == _HitRegion.chart || region == _HitRegion.xAxis) {
      newXMin = cursorX - (cursorX - _xVisibleMin!) * zoomFactor;
      newXMax = cursorX + (_xVisibleMax! - cursorX) * zoomFactor;
    }
    if (region == _HitRegion.chart || region == _HitRegion.yAxis) {
      newYMin = cursorY - (cursorY - _yVisibleMin!) * zoomFactor;
      newYMax = cursorY + (_yVisibleMax! - cursorY) * zoomFactor;
    }

    if ((newXMax - newXMin).abs() < 1e-10 ||
        (newYMax - newYMin).abs() < 1e-10) return;

    setState(() {
      _xVisibleMin = newXMin;
      _xVisibleMax = newXMax;
      _yVisibleMin = newYMin;
      _yVisibleMax = newYMax;
      _isGesturing = true;
    });

    _scrollEndTimer?.cancel();
    _scrollEndTimer = Timer(const Duration(milliseconds: 150), () {
      _endGesture();
    });
  }

  // ---------------------------------------------------------------------------
  // Trackpad detection: Listener callbacks fire BEFORE the GestureDetector's
  // ScaleGestureRecognizer processes the same events. We use them to tag
  // whether the current gesture is from a trackpad or mouse/touch.
  // ---------------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    _isTrackpadGesture = false;
    _isSecondaryButton = event.buttons & kSecondaryMouseButton != 0;
    _draggingAnnotationId = null;
    _draggingAnnotationType = null;

    // Hit-test draggable annotations (±8px threshold)
    if (!_isSecondaryButton) {
      final plotArea = _getPlotArea();
      if (plotArea != Rect.zero) {
        _hitTestDraggableAnnotations(event.localPosition, plotArea);
      }
    }

    // Detect Shift for rubber band zoom (not on right-click, not on annotation drag)
    _isRubberBand = !_isSecondaryButton &&
        _draggingAnnotationId == null &&
        HardwareKeyboard.instance.isShiftPressed;
    if (_isRubberBand) {
      _rubberBandStart = event.localPosition;
      _rubberBandEnd = event.localPosition;
    }
  }

  void _hitTestDraggableAnnotations(Offset pos, Rect plotArea) {
    for (final ann in widget.annotations) {
      final type = ann['type'] as String? ?? '';
      final id = ann['id'] as String?;
      if (id == null) continue;

      if (type == 'draggable_hline') {
        final y = (widget.renderState[id] as num?)?.toDouble()
            ?? (ann['y'] as num?)?.toDouble();
        if (y == null) continue;
        final screenY = _dataToScreenY(y, plotArea);
        if ((pos.dy - screenY).abs() <= 8.0) {
          _draggingAnnotationId = id;
          _draggingAnnotationType = type;
          return;
        }
      } else if (type == 'draggable_vline') {
        final x = (widget.renderState[id] as num?)?.toDouble()
            ?? (ann['x'] as num?)?.toDouble();
        if (x == null) continue;
        final screenX = _dataToScreenX(x, plotArea);
        if ((pos.dx - screenX).abs() <= 8.0) {
          _draggingAnnotationId = id;
          _draggingAnnotationType = type;
          return;
        }
      }
    }
  }

  double _dataToScreenY(double dataY, Rect plotArea) {
    final yMin = _yVisibleMin ?? widget.yAxis?.visibleRangeMin ?? 0.0;
    final yMax = _yVisibleMax ?? widget.yAxis?.visibleRangeMax ?? 100.0;
    final ratio = (dataY - yMin) / (yMax - yMin);
    return plotArea.bottom - ratio * plotArea.height;
  }

  double _dataToScreenX(double dataX, Rect plotArea) {
    final xMin = _xVisibleMin ?? widget.xAxis?.visibleRangeMin ?? 0.0;
    final xMax = _xVisibleMax ?? widget.xAxis?.visibleRangeMax ?? 100.0;
    final ratio = (dataX - xMin) / (xMax - xMin);
    return plotArea.left + ratio * plotArea.width;
  }

  void _onPointerPanZoomStart(PointerPanZoomStartEvent event) {
    _isTrackpadGesture = true;
  }

  void _onPointerUp(PointerUpEvent event) {
    // Right-click: undo zoom
    if (_isSecondaryButton) {
      _isSecondaryButton = false;
      _undoZoom();
      return;
    }

    // Click detection: only if this wasn't a drag
    if (_scaleStartFocalPoint != null) return; // was a drag

    // Undo/redo button clicks
    if (_undoRedoHitRects.length >= 2) {
      if (_undoRedoHitRects[0] != Rect.zero &&
          _undoRedoHitRects[0].contains(event.localPosition)) {
        _undoZoom();
        return;
      }
      if (_undoRedoHitRects[1] != Rect.zero &&
          _undoRedoHitRects[1].contains(event.localPosition)) {
        _redoZoom();
        return;
      }
    }

    // Legend click detection
    for (int i = 0; i < _legendHitRects.length; i++) {
      if (_legendHitRects[i].contains(event.localPosition)) {
        setState(() {
          if (_hiddenSeriesIndices.contains(i)) {
            _hiddenSeriesIndices.remove(i);
          } else {
            _hiddenSeriesIndices.add(i);
          }
        });
        return;
      }
    }
  }

  void _onHover(PointerHoverEvent event) {
    final region = _hitTest(event.localPosition);
    setState(() {
      _hoverPosition = region == _HitRegion.chart ? event.localPosition : null;
    });
  }

  void _onExit(PointerExitEvent event) {
    setState(() {
      _hoverPosition = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Rubber band zoom
  // ---------------------------------------------------------------------------

  /// Computed rubber band rect for the painter (null when not active).
  Rect? get _rubberBandRect {
    if (!_isRubberBand || _rubberBandStart == null || _rubberBandEnd == null) {
      return null;
    }
    return Rect.fromPoints(_rubberBandStart!, _rubberBandEnd!);
  }

  void _applyRubberBandZoom() {
    final plotArea = _getPlotArea();
    if (plotArea == Rect.zero) return;

    final start = _rubberBandStart!;
    final end = _rubberBandEnd!;

    // Clamp to plot area
    final left = math.min(start.dx, end.dx).clamp(plotArea.left, plotArea.right);
    final right = math.max(start.dx, end.dx).clamp(plotArea.left, plotArea.right);
    final top = math.min(start.dy, end.dy).clamp(plotArea.top, plotArea.bottom);
    final bottom = math.max(start.dy, end.dy).clamp(plotArea.top, plotArea.bottom);

    // Minimum selection size (avoid degenerate zooms from accidental clicks)
    if ((right - left) < 10 || (bottom - top) < 10) return;

    _ensureExplicitRanges();
    _pushViewportUndo();

    final newXMin = _screenToDataX(left, plotArea, _xVisibleMin!, _xVisibleMax!);
    final newXMax = _screenToDataX(right, plotArea, _xVisibleMin!, _xVisibleMax!);
    final newYMin = _screenToDataY(bottom, plotArea, _yVisibleMin!, _yVisibleMax!);
    final newYMax = _screenToDataY(top, plotArea, _yVisibleMin!, _yVisibleMax!);

    setState(() {
      _xVisibleMin = newXMin;
      _xVisibleMax = newXMax;
      _yVisibleMin = newYMin;
      _yVisibleMax = newYMax;
    });

    _notifyRangeChanged();
  }

  // ---------------------------------------------------------------------------
  // Scale gesture: handles drag-to-pan (mouse/touch), pinch-to-zoom
  // (touch/trackpad), and trackpad scroll-to-zoom.
  //
  // Uses _EagerScaleGestureRecognizer which immediately claims trackpad events
  // in the gesture arena, preventing parent ListView from competing.
  // ---------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    _stopMomentum(); // cancel any in-flight momentum from previous gesture
    if (_isSecondaryButton) return; // right-click handled separately
    if (_draggingAnnotationId != null) return; // annotation drag handled separately

    final region = _hitTest(details.localFocalPoint);
    if (region == _HitRegion.none) return;

    _ensureExplicitRanges();
    if (!_isRubberBand) {
      _pushViewportUndo(); // rubber band pushes in _applyRubberBandZoom
    }

    _scaleStartFocalPoint = details.localFocalPoint;
    _lastTrackpadFocalPoint = details.localFocalPoint;
    _scaleStartXMin = _xVisibleMin;
    _scaleStartXMax = _xVisibleMax;
    _scaleStartYMin = _yVisibleMin;
    _scaleStartYMax = _yVisibleMax;
    _gestureRegion = region;

    setState(() {
      _isGesturing = true;
    });
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Draggable annotation drag — update renderState directly
    if (_draggingAnnotationId != null) {
      final plotArea = _getPlotArea();
      if (plotArea == Rect.zero) return;

      if (_draggingAnnotationType == 'draggable_hline') {
        final yMin = _yVisibleMin ?? widget.yAxis?.visibleRangeMin ?? 0.0;
        final yMax = _yVisibleMax ?? widget.yAxis?.visibleRangeMax ?? 100.0;
        final ratio = (plotArea.bottom - details.localFocalPoint.dy) / plotArea.height;
        final newY = yMin + ratio * (yMax - yMin);
        widget.renderState[_draggingAnnotationId!] = newY;
      } else if (_draggingAnnotationType == 'draggable_vline') {
        final xMin = _xVisibleMin ?? widget.xAxis?.visibleRangeMin ?? 0.0;
        final xMax = _xVisibleMax ?? widget.xAxis?.visibleRangeMax ?? 100.0;
        final ratio = (details.localFocalPoint.dx - plotArea.left) / plotArea.width;
        final newX = xMin + ratio * (xMax - xMin);
        widget.renderState[_draggingAnnotationId!] = newX;
      }

      // Trigger repaint via setState + callback
      setState(() {});
      widget.onRenderStateChanged?.call();
      return;
    }

    if (_scaleStartFocalPoint == null) return;

    // Rubber band mode: just track the drag rectangle
    if (_isRubberBand) {
      setState(() {
        _rubberBandEnd = details.localFocalPoint;
      });
      return;
    }

    final plotArea = _getPlotArea();
    if (plotArea == Rect.zero || plotArea.width == 0 || plotArea.height == 0) {
      return;
    }

    final startXRange = _scaleStartXMax! - _scaleStartXMin!;
    final startYRange = _scaleStartYMax! - _scaleStartYMin!;

    double xMin = _scaleStartXMin!;
    double xMax = _scaleStartXMax!;
    double yMin = _scaleStartYMin!;
    double yMax = _scaleStartYMax!;

    if (_isTrackpadGesture && (details.scale - 1.0).abs() < 0.001) {
      // --- Trackpad scroll-to-zoom (incremental) ---
      // On macOS desktop, two-finger scroll arrives via ScaleGestureRecognizer
      // with scale=1.0. Use per-frame delta (not cumulative from start) for
      // smooth, inertial zoom that matches web feel.
      final dy = details.localFocalPoint.dy - _lastTrackpadFocalPoint!.dy;
      _lastTrackpadFocalPoint = details.localFocalPoint;

      // Use current ranges (not start ranges) since we apply incrementally
      xMin = _xVisibleMin!;
      xMax = _xVisibleMax!;
      yMin = _yVisibleMin!;
      yMax = _yVisibleMax!;

      final zoomAmount = -dy / 300.0;
      if (zoomAmount.abs() < 1e-6) return;
      final zoomFactor = 1.0 + zoomAmount.clamp(-0.15, 0.15);

      final cursorX = _screenToDataX(
          _scaleStartFocalPoint!.dx, plotArea, xMin, xMax);
      final cursorY = _screenToDataY(
          _scaleStartFocalPoint!.dy, plotArea, yMin, yMax);

      if (_gestureRegion == _HitRegion.chart ||
          _gestureRegion == _HitRegion.xAxis) {
        xMin = cursorX - (cursorX - xMin) * zoomFactor;
        xMax = cursorX + (xMax - cursorX) * zoomFactor;
      }
      if (_gestureRegion == _HitRegion.chart ||
          _gestureRegion == _HitRegion.yAxis) {
        yMin = cursorY - (cursorY - yMin) * zoomFactor;
        yMax = cursorY + (yMax - cursorY) * zoomFactor;
      }
    } else {
      // --- Mouse/touch: pan from focal point delta ---
      final dx = details.localFocalPoint.dx - _scaleStartFocalPoint!.dx;
      final dy = details.localFocalPoint.dy - _scaleStartFocalPoint!.dy;
      final dataXDelta = -dx / plotArea.width * startXRange;
      final dataYDelta = dy / plotArea.height * startYRange;

      xMin += dataXDelta;
      xMax += dataXDelta;
      yMin += dataYDelta;
      yMax += dataYDelta;

      // --- Zoom: apply pinch scale centered on focal point ---
      if ((details.scale - 1.0).abs() > 0.001) {
        // scale > 1 = fingers apart = zoom in = smaller data range
        final zoomFactor = 1.0 / details.scale;

        final focalX = _screenToDataX(
            details.localFocalPoint.dx, plotArea, xMin, xMax);
        final focalY = _screenToDataY(
            details.localFocalPoint.dy, plotArea, yMin, yMax);

        xMin = focalX - (focalX - xMin) * zoomFactor;
        xMax = focalX + (xMax - focalX) * zoomFactor;
        yMin = focalY - (focalY - yMin) * zoomFactor;
        yMax = focalY + (yMax - focalY) * zoomFactor;
      }
    }

    // Guard against degenerate ranges
    if ((xMax - xMin).abs() < 1e-10 || (yMax - yMin).abs() < 1e-10) return;

    setState(() {
      if (_gestureRegion == _HitRegion.chart ||
          _gestureRegion == _HitRegion.xAxis) {
        _xVisibleMin = xMin;
        _xVisibleMax = xMax;
      }
      if (_gestureRegion == _HitRegion.chart ||
          _gestureRegion == _HitRegion.yAxis) {
        _yVisibleMin = yMin;
        _yVisibleMax = yMax;
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Draggable annotation drag end — keep final value
    if (_draggingAnnotationId != null) {
      _draggingAnnotationId = null;
      _draggingAnnotationType = null;
      return;
    }

    // Rubber band zoom: apply selection
    if (_isRubberBand && _rubberBandStart != null && _rubberBandEnd != null) {
      _applyRubberBandZoom();
      _isRubberBand = false;
      _rubberBandStart = null;
      _rubberBandEnd = null;
      _scaleStartFocalPoint = null;
      _endGesture();
      return;
    }

    if (_isTrackpadGesture && _scaleStartFocalPoint != null) {
      // Start momentum animation if there's enough velocity.
      final vy = details.velocity.pixelsPerSecond.dy;
      if (vy.abs() > 50) {
        _startMomentum(vy);
        _scaleStartFocalPoint = null;
        return; // gesture stays "active" during momentum
      }
    }

    _scaleStartFocalPoint = null;
    _endGesture();
  }

  // ---------------------------------------------------------------------------
  // Momentum animation — simulates browser-style inertia for trackpad zoom
  // ---------------------------------------------------------------------------

  void _startMomentum(double velocityPxPerSec) {
    _stopMomentum();
    _momentumVelocity = velocityPxPerSec;
    _momentumCursor = _lastTrackpadFocalPoint ?? _scaleStartFocalPoint;
    _lastTickTime = null;
    _momentumTicker = createTicker(_onMomentumTick);
    _momentumTicker!.start();
  }

  void _stopMomentum() {
    _momentumTicker?.stop();
    _momentumTicker?.dispose();
    _momentumTicker = null;
  }

  void _onMomentumTick(Duration elapsed) {
    if (_lastTickTime == null) {
      _lastTickTime = elapsed;
      return;
    }

    final dt = (elapsed - _lastTickTime!).inMicroseconds / 1000000.0;
    _lastTickTime = elapsed;

    // Exponential friction: ~0.91 per frame at 60fps ≈ short, snappy
    // deceleration that feels responsive without abrupt stop.
    _momentumVelocity *= 0.91;

    if (_momentumVelocity.abs() < 10) {
      _stopMomentum();
      _endGesture();
      return;
    }

    // Convert velocity to a pixel delta for this frame
    final dy = _momentumVelocity * dt;
    _applyTrackpadZoomDelta(dy);
  }

  /// Apply a single trackpad zoom step from a pixel delta.
  void _applyTrackpadZoomDelta(double dy) {
    final plotArea = _getPlotArea();
    if (plotArea == Rect.zero) return;

    final zoomAmount = -dy / 300.0;
    if (zoomAmount.abs() < 1e-6) return;
    final zoomFactor = 1.0 + zoomAmount.clamp(-0.15, 0.15);

    double xMin = _xVisibleMin!;
    double xMax = _xVisibleMax!;
    double yMin = _yVisibleMin!;
    double yMax = _yVisibleMax!;

    final cursor = _momentumCursor ??
        Offset(plotArea.center.dx, plotArea.center.dy);
    final cursorX =
        _screenToDataX(cursor.dx, plotArea, xMin, xMax);
    final cursorY =
        _screenToDataY(cursor.dy, plotArea, yMin, yMax);

    if (_gestureRegion == _HitRegion.chart ||
        _gestureRegion == _HitRegion.xAxis) {
      xMin = cursorX - (cursorX - xMin) * zoomFactor;
      xMax = cursorX + (xMax - cursorX) * zoomFactor;
    }
    if (_gestureRegion == _HitRegion.chart ||
        _gestureRegion == _HitRegion.yAxis) {
      yMin = cursorY - (cursorY - yMin) * zoomFactor;
      yMax = cursorY + (yMax - cursorY) * zoomFactor;
    }

    if ((xMax - xMin).abs() < 1e-10 || (yMax - yMin).abs() < 1e-10) return;

    setState(() {
      _xVisibleMin = xMin;
      _xVisibleMax = xMax;
      _yVisibleMin = yMin;
      _yVisibleMax = yMax;
    });
  }

  // ---------------------------------------------------------------------------
  // Gesture end
  // ---------------------------------------------------------------------------

  void _endGesture() {
    setState(() {
      _isGesturing = false;
    });
    _notifyRangeChanged();
  }

  // ---------------------------------------------------------------------------
  // Double-tap reset
  // ---------------------------------------------------------------------------

  void _onDoubleTap() {
    ChartPainter.resetAutoRange();
    _pushViewportUndo(); // allow undo back to pre-reset view
    setState(() {
      _xVisibleMin = null;
      _xVisibleMax = null;
      _yVisibleMin = null;
      _yVisibleMax = null;
      _userHasZoomed = false;
      _isGesturing = false;
    });
    widget.onVisibleRangeChanged?.call(0, 0, 0, 0); // Signal reset
  }

  void _notifyRangeChanged() {
    if (_xVisibleMin != null && widget.onVisibleRangeChanged != null) {
      widget.onVisibleRangeChanged!(
        _xVisibleMin!,
        _xVisibleMax!,
        _yVisibleMin!,
        _yVisibleMax!,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build effective axes for the painter
  // ---------------------------------------------------------------------------

  AxisModel? get _effectiveXAxis {
    if (_xVisibleMin == null) return widget.xAxis;
    return (widget.xAxis ?? AxisModel(type: 'numeric')).copyWith(
      visibleRangeMin: _xVisibleMin,
      visibleRangeMax: _xVisibleMax,
      autoRange: 'never',
      growByMin: 0.0,
      growByMax: 0.0,
    );
  }

  AxisModel? get _effectiveYAxis {
    if (_yVisibleMin == null) return widget.yAxis;
    return (widget.yAxis ?? AxisModel(type: 'numeric')).copyWith(
      visibleRangeMin: _yVisibleMin,
      visibleRangeMax: _yVisibleMax,
      autoRange: 'never',
      growByMin: 0.0,
      growByMax: 0.0,
    );
  }

  // Secondary Y axis: pass through from widget (zoom/pan not yet independent)
  AxisModel? get _effectiveYAxis2 => widget.yAxis2;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerPanZoomStart: _onPointerPanZoomStart,
          onPointerUp: _onPointerUp,
          onPointerHover: _onHover,
          child: RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              _EagerScaleGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      _EagerScaleGestureRecognizer>(
                () => _EagerScaleGestureRecognizer(),
                (_EagerScaleGestureRecognizer instance) {
                  instance
                    ..onStart = _onScaleStart
                    ..onUpdate = _onScaleUpdate
                    ..onEnd = _onScaleEnd;
                },
              ),
              DoubleTapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                      DoubleTapGestureRecognizer>(
                () => DoubleTapGestureRecognizer(),
                (DoubleTapGestureRecognizer instance) {
                  instance.onDoubleTap = _onDoubleTap;
                },
              ),
            },
            child: MouseRegion(
              cursor: _isRubberBand
                  ? SystemMouseCursors.precise
                  : _isGesturing
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
              onExit: _onExit,
              child: CustomPaint(
                painter: ChartPainter(
                  xAxis: _effectiveXAxis,
                  yAxis: _effectiveYAxis,
                  yAxis2: _effectiveYAxis2,
                  series: widget.series,
                  dataBuffers: widget.dataBuffers,
                  backgroundColor: widget.backgroundColor,
                  showMajorGridLines: widget.showMajorGridLines,
                  showMinorGridLines: widget.showMinorGridLines,
                  majorGridLineColor: widget.majorGridLineColor,
                  minorGridLineColor: widget.minorGridLineColor,
                  gestureActive: _isGesturing,
                  legendHitRects: _legendHitRects,
                  hiddenSeriesIndices: _hiddenSeriesIndices,
                  hoverPosition: _isGesturing ? null : _hoverPosition,
                  rubberBandRect: _rubberBandRect,
                  annotations: widget.annotations,
                  canUndo: _undoStack.isNotEmpty,
                  canRedo: _redoStack.isNotEmpty,
                  undoRedoHitRects: _undoRedoHitRects,
                  renderState: widget.renderState,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Snapshot of viewport ranges for undo/redo history.
class _ViewportState {
  final double xMin, xMax, yMin, yMax;
  const _ViewportState(this.xMin, this.xMax, this.yMin, this.yMax);
}

enum _HitRegion { chart, xAxis, yAxis, none }
