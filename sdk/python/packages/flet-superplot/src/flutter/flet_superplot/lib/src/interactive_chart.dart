import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'models/axis_model.dart';
import 'models/series_model.dart';
import 'painters/chart_painter.dart';

/// Interactive chart widget with mouse wheel zoom, drag-to-pan, and
/// double-tap to reset. Wraps [ChartPainter] with gesture handling.
class InteractiveChart extends StatefulWidget {
  final AxisModel? xAxis;
  final AxisModel? yAxis;
  final List<SeriesModel> series;
  final Color backgroundColor;
  final bool showMajorGridLines;
  final bool showMinorGridLines;
  final Color majorGridLineColor;
  final Color minorGridLineColor;

  /// Zoom sensitivity: fraction of range per scroll tick (default 10%).
  final double zoomSensitivity;

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
    this.zoomSensitivity = 0.1,
    this.onVisibleRangeChanged,
  });

  @override
  State<InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<InteractiveChart> {
  // Mutable visible ranges. Null = use axis config / auto-range.
  double? _xVisibleMin;
  double? _xVisibleMax;
  double? _yVisibleMin;
  double? _yVisibleMax;

  // Whether the user has explicitly zoomed/panned (vs default view)
  bool _userHasZoomed = false;

  // Gesture state
  bool _isGesturing = false;
  Offset? _panStartScreen;
  double? _panStartXMin;
  double? _panStartXMax;
  double? _panStartYMin;
  double? _panStartYMax;
  _HitRegion _panRegion = _HitRegion.chart;

  // Debounce timer for scroll gesture end
  Timer? _scrollEndTimer;

  // Last known widget size (from LayoutBuilder)
  Size _lastSize = Size.zero;

  @override
  void dispose() {
    _scrollEndTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(InteractiveChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If parent pushes new axis config while user hasn't zoomed, respect it
    if (!_userHasZoomed) {
      ChartPainter.resetStaticPlotArea();
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
  /// Reuses the last tick-based plot area from ChartPainter so the mapping
  /// matches what was rendered — no jump at gesture start.
  Rect _getPlotArea() {
    if (_xVisibleMin == null || _lastSize == Size.zero) return Rect.zero;
    // Use the cached tick-based plot area from the last static frame.
    // Falls back to fixed insets if no static frame has been painted yet.
    return ChartPainter.lastStaticPlotArea ??
        Rect.fromLTRB(
          10.0,
          10.0,
          _lastSize.width - ChartPainter.rightAxisWidth - 11.0,
          _lastSize.height - ChartPainter.bottomAxisHeight - 3.0,
        );
  }

  /// Determine which region a local position falls in.
  /// - chart: main plot area → zoom/pan both axes
  /// - xAxis: bottom axis strip → zoom/pan X only
  /// - yAxis: right axis strip → zoom/pan Y only
  /// - none: corner or outside
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
  // Mouse wheel zoom
  // ---------------------------------------------------------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final region = _hitTest(event.localPosition);
      if (region == _HitRegion.none) return;

      _ensureExplicitRanges();
      final plotArea = _getPlotArea();
      if (plotArea == Rect.zero) return;

      // Scale zoom by scroll delta. Divisor tuned for smooth feel:
      // Mouse wheel (~100px/tick): ~5% zoom. Trackpad (~5px/event): ~0.3%.
      final rawDelta = event.scrollDelta.dy;
      if (rawDelta.abs() < 0.5) return; // Ignore sub-pixel momentum
      final zoomAmount = rawDelta / 1500.0;
      final zoomFactor = 1.0 + zoomAmount.clamp(-0.15, 0.15);

      // Zoom centered on cursor (or axis midpoint for axis regions)
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

      // Apply zoom to the appropriate axis/axes based on hit region
      if (region == _HitRegion.chart || region == _HitRegion.xAxis) {
        newXMin = cursorX - (cursorX - _xVisibleMin!) * zoomFactor;
        newXMax = cursorX + (_xVisibleMax! - cursorX) * zoomFactor;
      }
      if (region == _HitRegion.chart || region == _HitRegion.yAxis) {
        newYMin = cursorY - (cursorY - _yVisibleMin!) * zoomFactor;
        newYMax = cursorY + (_yVisibleMax! - cursorY) * zoomFactor;
      }

      // Guard against degenerate ranges
      if ((newXMax - newXMin).abs() < 1e-10 ||
          (newYMax - newYMin).abs() < 1e-10) return;

      setState(() {
        _xVisibleMin = newXMin;
        _xVisibleMax = newXMax;
        _yVisibleMin = newYMin;
        _yVisibleMax = newYMax;
        _isGesturing = true;
      });

      // Debounce: mark gesture as ended 150ms after last scroll
      _scrollEndTimer?.cancel();
      _scrollEndTimer = Timer(const Duration(milliseconds: 150), () {
        _endGesture();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Drag pan
  // ---------------------------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    final region = _hitTest(details.localPosition);
    if (region == _HitRegion.none) return;

    _ensureExplicitRanges();

    _panStartScreen = details.localPosition;
    _panStartXMin = _xVisibleMin;
    _panStartXMax = _xVisibleMax;
    _panStartYMin = _yVisibleMin;
    _panStartYMax = _yVisibleMax;
    _panRegion = region;

    setState(() {
      _isGesturing = true;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_panStartScreen == null) return;

    final plotArea = _getPlotArea();
    if (plotArea == Rect.zero || plotArea.width == 0 || plotArea.height == 0) {
      return;
    }

    final dx = details.localPosition.dx - _panStartScreen!.dx;
    final dy = details.localPosition.dy - _panStartScreen!.dy;

    final xRange = _panStartXMax! - _panStartXMin!;
    final yRange = _panStartYMax! - _panStartYMin!;

    // Drag right → view pans left → data range decreases
    final dataXDelta = -dx / plotArea.width * xRange;
    // Drag down → view pans up → data range increases (Y is inverted)
    final dataYDelta = dy / plotArea.height * yRange;

    setState(() {
      // Apply pan to appropriate axes based on where the drag started
      if (_panRegion == _HitRegion.chart || _panRegion == _HitRegion.xAxis) {
        _xVisibleMin = _panStartXMin! + dataXDelta;
        _xVisibleMax = _panStartXMax! + dataXDelta;
      }
      if (_panRegion == _HitRegion.chart || _panRegion == _HitRegion.yAxis) {
        _yVisibleMin = _panStartYMin! + dataYDelta;
        _yVisibleMax = _panStartYMax! + dataYDelta;
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _panStartScreen = null;
    _endGesture();
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
    ChartPainter.resetStaticPlotArea();
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
          child: GestureDetector(
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            onDoubleTap: _onDoubleTap,
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
