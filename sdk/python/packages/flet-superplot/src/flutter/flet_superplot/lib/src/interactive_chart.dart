import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
  final List<SeriesModel> series;
  final Color backgroundColor;
  final bool showMajorGridLines;
  final bool showMinorGridLines;
  final Color majorGridLineColor;
  final Color minorGridLineColor;

  /// Callback fired when visible range changes (on gesture end).
  final void Function(double xMin, double xMax, double yMin, double yMax)?
      onVisibleRangeChanged;

  const InteractiveChart({
    super.key,
    this.xAxis,
    this.yAxis,
    required this.series,
    required this.backgroundColor,
    required this.showMajorGridLines,
    required this.showMinorGridLines,
    required this.majorGridLineColor,
    required this.minorGridLineColor,
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

  @override
  void dispose() {
    _scrollEndTimer?.cancel();
    _stopMomentum();
    super.dispose();
  }

  @override
  void didUpdateWidget(InteractiveChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If parent pushes new axis config while user hasn't zoomed, respect it
    if (!_userHasZoomed) {
      _xVisibleMin = null;
      _xVisibleMax = null;
      _yVisibleMin = null;
      _yVisibleMax = null;
    }
  }

  /// Ensure we have explicit mutable ranges (called on first interaction).
  void _ensureExplicitRanges() {
    if (_xVisibleMin != null) return;

    // Compute what the painter would use as visible ranges
    final xAxis = widget.xAxis;
    final yAxis = widget.yAxis;

    double xMin = xAxis?.visibleRangeMin ?? double.infinity;
    double xMax = xAxis?.visibleRangeMax ?? double.negativeInfinity;
    double yMin = yAxis?.visibleRangeMin ?? double.infinity;
    double yMax = yAxis?.visibleRangeMax ?? double.negativeInfinity;

    // Auto-range from data if needed
    final xAutoRange = xAxis?.autoRange != 'never';
    final yAutoRange = yAxis?.autoRange != 'never';

    if (xAutoRange || yAutoRange) {
      for (final s in widget.series) {
        if (s.data == null || s.data!.isEmpty) continue;
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

    // Apply grow-by
    if (xMin.isFinite && xMax.isFinite) {
      final xRange = xMax - xMin;
      if (xRange > 0) {
        xMin -= xRange * (xAxis?.growByMin ?? 0.1);
        xMax += xRange * (xAxis?.growByMax ?? 0.1);
      }
    } else {
      xMin = 0;
      xMax = 1;
    }

    if (yMin.isFinite && yMax.isFinite) {
      final yRange = yMax - yMin;
      if (yRange > 0) {
        yMin -= yRange * (yAxis?.growByMin ?? 0.1);
        yMax += yRange * (yAxis?.growByMax ?? 0.1);
      }
    } else {
      yMin = 0;
      yMax = 1;
    }

    _xVisibleMin = xMin;
    _xVisibleMax = xMax;
    _yVisibleMin = yMin;
    _yVisibleMax = yMax;
    _userHasZoomed = true;
  }

  /// Get the plot area for coordinate conversion during gestures.
  /// Uses the same simple inset-based mapping as ChartPainter.
  Rect _getPlotArea() {
    if (_xVisibleMin == null || _lastSize == Size.zero) return Rect.zero;
    return ChartPainter.computePlotArea(size: _lastSize);
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

    final zoomAmount = event.scrollDelta.dy / 1500.0;
    if (zoomAmount.abs() < 1e-6) return;
    final zoomFactor = 1.0 + zoomAmount.clamp(-0.15, 0.15);

    final cursorX = ChartPainter.screenToDataX(
        event.localPosition.dx.clamp(0, plotArea.right),
        plotArea, _xVisibleMin!, _xVisibleMax!);
    final cursorY = ChartPainter.screenToDataY(
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
  }

  void _onPointerPanZoomStart(PointerPanZoomStartEvent event) {
    _isTrackpadGesture = true;
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

    final region = _hitTest(details.localFocalPoint);
    if (region == _HitRegion.none) return;

    _ensureExplicitRanges();

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
    if (_scaleStartFocalPoint == null) return;

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

      final cursorX = ChartPainter.screenToDataX(
          _scaleStartFocalPoint!.dx, plotArea, xMin, xMax);
      final cursorY = ChartPainter.screenToDataY(
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

        final focalX = ChartPainter.screenToDataX(
            details.localFocalPoint.dx, plotArea, xMin, xMax);
        final focalY = ChartPainter.screenToDataY(
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
        ChartPainter.screenToDataX(cursor.dx, plotArea, xMin, xMax);
    final cursorY =
        ChartPainter.screenToDataY(cursor.dy, plotArea, yMin, yMax);

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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerSignal: _onPointerSignal,
          onPointerDown: _onPointerDown,
          onPointerPanZoomStart: _onPointerPanZoomStart,
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
              cursor: _isGesturing
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.grab,
              child: CustomPaint(
                painter: ChartPainter(
                  xAxis: _effectiveXAxis,
                  yAxis: _effectiveYAxis,
                  series: widget.series,
                  backgroundColor: widget.backgroundColor,
                  showMajorGridLines: widget.showMajorGridLines,
                  showMinorGridLines: widget.showMinorGridLines,
                  majorGridLineColor: widget.majorGridLineColor,
                  minorGridLineColor: widget.minorGridLineColor,
                  gestureActive: _isGesturing,
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

enum _HitRegion { chart, xAxis, yAxis, none }
