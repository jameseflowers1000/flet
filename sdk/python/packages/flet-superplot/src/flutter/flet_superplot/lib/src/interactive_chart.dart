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

  /// Get the current plot area for coordinate conversion.
  Rect _getPlotArea() {
    if (_xVisibleMin == null || _lastSize == Size.zero) return Rect.zero;
    return ChartPainter.computePlotArea(
      size: _lastSize,
      xMin: _xVisibleMin!,
      xMax: _xVisibleMax!,
      yMin: _yVisibleMin!,
      yMax: _yVisibleMax!,
      xDataMin: _xVisibleMin!,
      xDataMax: _xVisibleMax!,
      yDataMin: _yVisibleMin!,
      yDataMax: _yVisibleMax!,
    );
  }

  /// Check if a local position is within the chart area (not axis labels).
  bool _isInChartArea(Offset localPosition) {
    final chartClip = Rect.fromLTRB(
      0,
      0,
      _lastSize.width - ChartPainter.rightAxisWidth,
      _lastSize.height - ChartPainter.bottomAxisHeight,
    );
    return chartClip.contains(localPosition);
  }

  // ---------------------------------------------------------------------------
  // Mouse wheel zoom
  // ---------------------------------------------------------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isInChartArea(event.localPosition)) return;

      _ensureExplicitRanges();
      final plotArea = _getPlotArea();
      if (plotArea == Rect.zero) return;

      final scrollDelta = event.scrollDelta.dy;
      final zoomFactor = scrollDelta > 0
          ? (1 + widget.zoomSensitivity)
          : (1 / (1 + widget.zoomSensitivity));

      // Zoom centered on cursor in data coordinates
      final cursorX = ChartPainter.screenToDataX(
          event.localPosition.dx, plotArea, _xVisibleMin!, _xVisibleMax!);
      final cursorY = ChartPainter.screenToDataY(
          event.localPosition.dy, plotArea, _yVisibleMin!, _yVisibleMax!);

      final newXMin = cursorX - (cursorX - _xVisibleMin!) * zoomFactor;
      final newXMax = cursorX + (_xVisibleMax! - cursorX) * zoomFactor;
      final newYMin = cursorY - (cursorY - _yVisibleMin!) * zoomFactor;
      final newYMax = cursorY + (_yVisibleMax! - cursorY) * zoomFactor;

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
        setState(() {
          _isGesturing = false;
        });
        _notifyRangeChanged();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Drag pan
  // ---------------------------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    if (!_isInChartArea(details.localPosition)) return;

    _ensureExplicitRanges();

    _panStartScreen = details.localPosition;
    _panStartXMin = _xVisibleMin;
    _panStartXMax = _xVisibleMax;
    _panStartYMin = _yVisibleMin;
    _panStartYMax = _yVisibleMax;

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
      _xVisibleMin = _panStartXMin! + dataXDelta;
      _xVisibleMax = _panStartXMax! + dataXDelta;
      _yVisibleMin = _panStartYMin! + dataYDelta;
      _yVisibleMax = _panStartYMax! + dataYDelta;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _panStartScreen = null;
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
