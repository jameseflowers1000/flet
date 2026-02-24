import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/axis_model.dart';
import '../models/series_model.dart';

/// Main chart painter - renders axes, grid, and series data.
///
/// Uses CustomPainter for efficient GPU-accelerated rendering.
/// Designed for pixel-level compatibility with SciChart output.
class ChartPainter extends CustomPainter {
  final AxisModel? xAxis;
  final AxisModel? yAxis;
  final List<SeriesModel> series;
  final Color backgroundColor;
  final bool showMajorGridLines;
  final bool showMinorGridLines;
  final Color majorGridLineColor;
  final Color minorGridLineColor;

  /// When true, skip expensive axis label rebuilds (replay stale cache).
  /// Set during active pan/zoom gestures to maintain 60fps.
  final bool gestureActive;

  /// Legend support: mutable list populated during paint() for hit testing.
  final List<Rect> legendHitRects;

  /// Set of series indices to hide (toggled via legend clicks).
  final Set<int> hiddenSeriesIndices;

  /// Hover position for crosshair/tooltip (null when not hovering or during gesture).
  final Offset? hoverPosition;

  /// Rubber band selection rectangle (null when not selecting).
  final Rect? rubberBandRect;

  /// Chart annotations (horizontal/vertical lines, text, boxes).
  final List<Map<String, dynamic>> annotations;

  /// Whether undo/redo are available (controls button rendering).
  final bool canUndo;
  final bool canRedo;

  /// Hit rects for undo/redo buttons, populated during paint: [0]=undo, [1]=redo.
  final List<Rect> undoRedoHitRects;

  // Computed during paint
  late Rect _plotArea;
  late Rect _chartClip;
  late double _xMin, _xMax, _yMin, _yMax;
  late double _xDataMin, _xDataMax, _yDataMin, _yDataMax;

  // Layout constants (matching SciChart defaults)
  static const double rightAxisWidth = 70.0;
  static const double bottomAxisHeight = 52.0;

  // Cached pictures for grid and axes (expensive TextPainter work).
  // Split into two layers: grid (behind data) and axes (on top of data).
  static ui.Picture? _gridCache;
  static ui.Picture? _axesCache;
  static String _gridCacheKey = '';
  static String _axesCacheKey = '';

  // Layout insets matching SciChart defaults
  static const double leftInset = 10.0;
  static const double topInset = 10.0;
  static const double rightInset = 11.0;
  static const double bottomInset = 3.0;

  ChartPainter({
    this.xAxis,
    this.yAxis,
    required this.series,
    required this.backgroundColor,
    required this.showMajorGridLines,
    required this.showMinorGridLines,
    required this.majorGridLineColor,
    required this.minorGridLineColor,
    this.gestureActive = false,
    required this.legendHitRects,
    required this.hiddenSeriesIndices,
    this.hoverPosition,
    this.rubberBandRect,
    this.annotations = const [],
    this.canUndo = false,
    this.canRedo = false,
    required this.undoRedoHitRects,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fill background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    // Chart clip rect: visible area excluding axis label areas
    _chartClip = Rect.fromLTRB(
      0,
      0,
      size.width - rightAxisWidth,
      size.height - bottomAxisHeight,
    );

    try {
      _computeRanges();
    } catch (e) {
      debugPrint('[SuperPlot] _computeRanges error: $e');
      _xMin = 0; _xMax = 1; _yMin = 0; _yMax = 1;
      _xDataMin = 0; _xDataMax = 1; _yDataMin = 0; _yDataMax = 1;
    }

    try {
      _computePlotArea();
    } catch (e) {
      debugPrint('[SuperPlot] _computePlotArea error: $e');
      _plotArea = _chartClip;
    }

    // Cache keys include all properties that affect each layer's rendering
    final rangeKey = '${size.width},${size.height},'
        '$_xMin,$_xMax,$_yMin,$_yMax,'
        '$_xDataMin,$_xDataMax,$_yDataMin,$_yDataMax';
    final gridCacheKey = '$rangeKey,'
        '$showMajorGridLines,$showMinorGridLines,'
        '${majorGridLineColor.value},${minorGridLineColor.value}';
    final axesCacheKey = '$rangeKey,'
        '${xAxis?.axisTitle},${yAxis?.axisTitle},'
        '${xAxis?.labelFormat},${yAxis?.labelFormat},'
        '${xAxis?.type},${yAxis?.type}';

    // --- Grid layer ---
    if (_gridCache == null || _gridCacheKey != gridCacheKey) {
      final gridRec = ui.PictureRecorder();
      final gridCanvas = Canvas(gridRec);
      try {
        _drawGridLines(gridCanvas, size);
      } catch (e) {
        debugPrint('[SuperPlot] _drawGridLines error: $e');
      }
      _gridCache = gridRec.endRecording();
      _gridCacheKey = gridCacheKey;
    }

    // --- Axes layer ---
    if (_axesCache == null || _axesCacheKey != axesCacheKey) {
      final axesRec = ui.PictureRecorder();
      final axesCanvas = Canvas(axesRec);
      try {
        _drawXAxis(axesCanvas, size);
      } catch (e) {
        debugPrint('[SuperPlot] _drawXAxis error: $e');
      }
      try {
        _drawYAxis(axesCanvas, size);
      } catch (e) {
        debugPrint('[SuperPlot] _drawYAxis error: $e');
      }
      _axesCache = axesRec.endRecording();
      _axesCacheKey = axesCacheKey;
    }

    // Draw: grid → annotations → series → axes
    canvas.drawPicture(_gridCache!);

    // Annotations: render between grid and series
    if (annotations.isNotEmpty) {
      canvas.save();
      canvas.clipRect(_chartClip);
      try {
        _drawAnnotations(canvas);
      } catch (e) {
        debugPrint('[SuperPlot] _drawAnnotations error: $e');
      }
      canvas.restore();
    }

    for (int i = 0; i < series.length; i++) {
      final s = series[i];
      if (s.isVisible && !hiddenSeriesIndices.contains(i) &&
          s.data != null && s.data!.length > 0) {
        try {
          _drawSeries(canvas, s);
        } catch (e) {
          debugPrint('[SuperPlot] _drawSeries error: $e');
        }
      }
    }

    if (_axesCache != null) {
      canvas.drawPicture(_axesCache!);
    }

    // Legend: draw after axes, only when multiple series
    if (series.length > 1) {
      try {
        _drawLegend(canvas, size);
      } catch (e) {
        debugPrint('[SuperPlot] _drawLegend error: $e');
      }
    }

    // Undo/redo buttons: draw after legend, before crosshair
    try {
      _drawUndoRedo(canvas, size);
    } catch (e) {
      debugPrint('[SuperPlot] _drawUndoRedo error: $e');
    }

    // Crosshair + tooltip on hover
    if (hoverPosition != null) {
      try {
        _drawCrosshair(canvas, size);
      } catch (e) {
        debugPrint('[SuperPlot] _drawCrosshair error: $e');
      }
    }

    // Rubber band selection rectangle
    if (rubberBandRect != null) {
      // Semi-transparent fill
      canvas.drawRect(
        rubberBandRect!,
        Paint()..color = const Color(0x224488FF),
      );
      // Dashed-style border
      canvas.drawRect(
        rubberBandRect!,
        Paint()
          ..color = const Color(0xAA4488FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Public static helpers for coordinate conversion (used by InteractiveChart)
  // ---------------------------------------------------------------------------

  /// Compute the plot area rect for a given canvas size.
  /// Simple inset-based mapping: the full visible range maps exactly to
  /// the chart clip area minus insets. This ensures no clipping at any zoom.
  static Rect computePlotArea({required Size size}) {
    return Rect.fromLTRB(
      leftInset,
      topInset,
      size.width - rightAxisWidth - rightInset,
      size.height - bottomAxisHeight - bottomInset,
    );
  }

  /// Convert screen X coordinate to data X value.
  static double screenToDataX(
      double screenX, Rect plotArea, double xMin, double xMax,
      {bool isLogarithmic = false, double logarithmicBase = 10.0}) {
    final ratio = (screenX - plotArea.left) / plotArea.width;
    if (isLogarithmic) {
      final logBase = math.log(logarithmicBase);
      final logMin = math.log(xMin.clamp(1e-100, double.infinity)) / logBase;
      final logMax = math.log(xMax.clamp(1e-100, double.infinity)) / logBase;
      final logVal = logMin + ratio * (logMax - logMin);
      return math.pow(logarithmicBase, logVal).toDouble();
    }
    return xMin + ratio * (xMax - xMin);
  }

  /// Convert screen Y coordinate to data Y value (Y is inverted).
  static double screenToDataY(
      double screenY, Rect plotArea, double yMin, double yMax,
      {bool isLogarithmic = false, double logarithmicBase = 10.0}) {
    final ratio = (plotArea.bottom - screenY) / plotArea.height;
    if (isLogarithmic) {
      final logBase = math.log(logarithmicBase);
      final logMin = math.log(yMin.clamp(1e-100, double.infinity)) / logBase;
      final logMax = math.log(yMax.clamp(1e-100, double.infinity)) / logBase;
      final logVal = logMin + ratio * (logMax - logMin);
      return math.pow(logarithmicBase, logVal).toDouble();
    }
    return yMin + ratio * (yMax - yMin);
  }

  /// Calculate nice tick values for a given range.
  static List<double> calculateTicks(
      double min, double max, int targetCount) {
    if (!min.isFinite || !max.isFinite || min >= max) {
      return [0, 1];
    }

    final range = max - min;
    final rawStep = range / targetCount;

    final magnitude = math.pow(10, (math.log(rawStep) / math.ln10).floor());
    final normalizedStep = rawStep / magnitude;

    double niceStep;
    if (normalizedStep <= 1.5) {
      niceStep = 1;
    } else if (normalizedStep <= 3) {
      niceStep = 2;
    } else if (normalizedStep <= 7) {
      niceStep = 5;
    } else {
      niceStep = 10;
    }
    niceStep *= magnitude.toDouble();

    final firstTick = (min / niceStep).ceil() * niceStep;
    final ticks = <double>[];

    for (double tick = firstTick; tick <= max; tick += niceStep) {
      ticks.add(tick);
    }

    return ticks;
  }

  /// Calculate tick values for a logarithmic axis.
  /// Ticks at each power of the base AND at 3× each power (matching SciChart
  /// default behavior: 1, 3, 10, 30, 100, 300, ...).
  static List<double> calculateLogTicks(double min, double max, double base) {
    if (min <= 0) min = 1e-100;
    if (max <= min) return [min];

    final logBase = math.log(base);
    final logMin = (math.log(min) / logBase).floor();
    final logMax = (math.log(max) / logBase).ceil();
    final ticks = <double>[];
    for (int p = logMin; p <= logMax; p++) {
      final tick = math.pow(base, p).toDouble();
      if (tick >= min * 0.999 && tick <= max * 1.001) {
        ticks.add(tick);
      }
      // Intermediate tick at 3× (half-decade in log space)
      final midTick = 3 * tick;
      if (midTick >= min * 0.999 && midTick <= max * 1.001) {
        ticks.add(midTick);
      }
    }
    ticks.sort();
    return ticks;
  }

  // ---------------------------------------------------------------------------
  // Internal methods
  // ---------------------------------------------------------------------------

  void _computeRanges() {
    _xMin = xAxis?.visibleRangeMin ?? double.infinity;
    _xMax = xAxis?.visibleRangeMax ?? double.negativeInfinity;
    _yMin = yAxis?.visibleRangeMin ?? double.infinity;
    _yMax = yAxis?.visibleRangeMax ?? double.negativeInfinity;

    final xAutoRange = xAxis?.autoRange != 'never';
    final yAutoRange = yAxis?.autoRange != 'never';

    if (xAutoRange || yAutoRange) {
      for (final s in series) {
        if (s.data == null || s.data!.isEmpty) continue;
        if (xAutoRange) {
          final (dataXMin, dataXMax) = s.data!.xRange;
          if (dataXMin < _xMin) _xMin = dataXMin;
          if (dataXMax > _xMax) _xMax = dataXMax;
        }
        if (yAutoRange) {
          final (dataYMin, dataYMax) = s.data!.yRange;
          if (dataYMin < _yMin) _yMin = dataYMin;
          if (dataYMax > _yMax) _yMax = dataYMax;
        }
      }
    }

    _xDataMin = _xMin.isFinite ? _xMin : 0;
    _xDataMax = _xMax.isFinite ? _xMax : 1;
    _yDataMin = _yMin.isFinite ? _yMin : 0;
    _yDataMax = _yMax.isFinite ? _yMax : 1;

    if (_xMin.isFinite && _xMax.isFinite) {
      if (xAxis?.isLogarithmic == true) {
        // Multiplicative grow-by in log space
        final base = xAxis!.logarithmicBase ?? 10.0;
        if (_xMin > 0 && _xMax > _xMin) {
          _xMin = _xMin / math.pow(base, xAxis!.growByMin);
          _xMax = _xMax * math.pow(base, xAxis!.growByMax);
        } else {
          _xMin = 0.1;
          _xMax = 10;
        }
      } else {
        final xRange = _xMax - _xMin;
        if (xRange > 0) {
          _xMin -= xRange * (xAxis?.growByMin ?? 0.1);
          _xMax += xRange * (xAxis?.growByMax ?? 0.1);
        } else {
          _xMin -= 1;
          _xMax += 1;
        }
      }
    } else {
      _xMin = xAxis?.isLogarithmic == true ? 0.1 : 0;
      _xMax = xAxis?.isLogarithmic == true ? 10 : 1;
    }

    if (_yMin.isFinite && _yMax.isFinite) {
      if (yAxis?.isLogarithmic == true) {
        // Multiplicative grow-by in log space
        final base = yAxis!.logarithmicBase ?? 10.0;
        if (_yMin > 0 && _yMax > _yMin) {
          _yMin = _yMin / math.pow(base, yAxis!.growByMin);
          _yMax = _yMax * math.pow(base, yAxis!.growByMax);
        } else {
          _yMin = 0.1;
          _yMax = 10;
        }
      } else {
        final yRange = _yMax - _yMin;
        if (yRange > 0) {
          _yMin -= yRange * (yAxis?.growByMin ?? 0.1);
          _yMax += yRange * (yAxis?.growByMax ?? 0.1);
        } else {
          _yMin -= 1;
          _yMax += 1;
        }
      }
    } else {
      _yMin = yAxis?.isLogarithmic == true ? 0.1 : 0;
      _yMax = yAxis?.isLogarithmic == true ? 10 : 1;
    }
  }

  void _computePlotArea() {
    // Simple inset-based mapping: the full visible range [_xMin, _xMax]
    // maps exactly to the chart clip minus insets. This guarantees grid
    // lines, axis labels, and data series all stay within the visible area
    // at any zoom level — no clipping.
    _plotArea = Rect.fromLTRB(
      _chartClip.left + leftInset,
      _chartClip.top + topInset,
      _chartClip.right - rightInset,
      _chartClip.bottom - bottomInset,
    );
  }

  double _dataToScreenX(double dataX) {
    if (xAxis?.isLogarithmic == true) {
      final base = xAxis!.logarithmicBase ?? 10.0;
      final logBase = math.log(base);
      final logMin = math.log(_xMin.clamp(1e-100, double.infinity)) / logBase;
      final logMax = math.log(_xMax.clamp(1e-100, double.infinity)) / logBase;
      final logVal = math.log(dataX.clamp(1e-100, double.infinity)) / logBase;
      final ratio = (logVal - logMin) / (logMax - logMin);
      return _plotArea.left + ratio * _plotArea.width;
    }
    final ratio = (dataX - _xMin) / (_xMax - _xMin);
    return _plotArea.left + ratio * _plotArea.width;
  }

  double _dataToScreenY(double dataY) {
    if (yAxis?.isLogarithmic == true) {
      final base = yAxis!.logarithmicBase ?? 10.0;
      final logBase = math.log(base);
      final logMin = math.log(_yMin.clamp(1e-100, double.infinity)) / logBase;
      final logMax = math.log(_yMax.clamp(1e-100, double.infinity)) / logBase;
      final logVal = math.log(dataY.clamp(1e-100, double.infinity)) / logBase;
      final ratio = (logVal - logMin) / (logMax - logMin);
      return _plotArea.bottom - ratio * _plotArea.height;
    }
    final ratio = (dataY - _yMin) / (_yMax - _yMin);
    return _plotArea.bottom - ratio * _plotArea.height;
  }

  void _drawGridLines(Canvas canvas, Size size) {
    final majorPaint = Paint()
      ..color = majorGridLineColor
      ..strokeWidth = 1.0;

    final xIsLog = xAxis?.isLogarithmic == true;
    final yIsLog = yAxis?.isLogarithmic == true;
    final xLogBase = xAxis?.logarithmicBase ?? 10.0;
    final yLogBase = yAxis?.logarithmicBase ?? 10.0;

    final xTicks = xIsLog
        ? calculateLogTicks(_xMin, _xMax, xLogBase)
        : calculateTicks(_xMin, _xMax, xAxis?.majorTickCount ?? 10);
    final yTicks = yIsLog
        ? calculateLogTicks(_yMin, _yMax, yLogBase)
        : calculateTicks(_yMin, _yMax, yAxis?.majorTickCount ?? 10);

    // Minor grid lines
    if (showMinorGridLines) {
      final minorPaint = Paint()
        ..color = minorGridLineColor
        ..strokeWidth = 0.5;

      // Minor X grid lines
      if (xTicks.length >= 2) {
        if (xIsLog) {
          _drawLogMinorGridLinesX(canvas, xTicks, xLogBase, minorPaint);
        } else {
          _drawLinearMinorGridLinesX(canvas, xTicks, minorPaint);
        }
      }

      // Minor Y grid lines
      if (yTicks.length >= 2) {
        if (yIsLog) {
          _drawLogMinorGridLinesY(canvas, yTicks, yLogBase, minorPaint);
        } else {
          _drawLinearMinorGridLinesY(canvas, yTicks, minorPaint);
        }
      }
    }

    if (showMajorGridLines) {
      for (final tick in xTicks) {
        final x = _dataToScreenX(tick);
        if (x >= _chartClip.left && x <= _chartClip.right) {
          canvas.drawLine(
            Offset(x, _chartClip.top),
            Offset(x, _chartClip.bottom),
            majorPaint,
          );
        }
      }
      for (final tick in yTicks) {
        final y = _dataToScreenY(tick);
        if (y >= _chartClip.top && y <= _chartClip.bottom) {
          canvas.drawLine(
            Offset(_chartClip.left, y),
            Offset(_chartClip.right, y),
            majorPaint,
          );
        }
      }
    }
  }

  void _drawLinearMinorGridLinesX(Canvas canvas, List<double> ticks, Paint paint) {
    const int minorDivisions = 5;
    for (int i = 0; i < ticks.length - 1; i++) {
      final step = (ticks[i + 1] - ticks[i]) / minorDivisions;
      for (int j = 1; j < minorDivisions; j++) {
        final x = _dataToScreenX(ticks[i] + j * step);
        if (x >= _chartClip.left && x <= _chartClip.right) {
          canvas.drawLine(Offset(x, _chartClip.top), Offset(x, _chartClip.bottom), paint);
        }
      }
    }
  }

  void _drawLinearMinorGridLinesY(Canvas canvas, List<double> ticks, Paint paint) {
    const int minorDivisions = 5;
    for (int i = 0; i < ticks.length - 1; i++) {
      final step = (ticks[i + 1] - ticks[i]) / minorDivisions;
      for (int j = 1; j < minorDivisions; j++) {
        final y = _dataToScreenY(ticks[i] + j * step);
        if (y >= _chartClip.top && y <= _chartClip.bottom) {
          canvas.drawLine(Offset(_chartClip.left, y), Offset(_chartClip.right, y), paint);
        }
      }
    }
  }

  void _drawLogMinorGridLinesX(Canvas canvas, List<double> ticks, double base, Paint paint) {
    // Minor ticks at 2, 3, ..., base-1 between each decade
    final baseInt = base.toInt();
    for (int i = 0; i < ticks.length - 1; i++) {
      for (int m = 2; m < baseInt; m++) {
        final minorTick = ticks[i] * m;
        if (minorTick >= ticks[i + 1]) break;
        final x = _dataToScreenX(minorTick);
        if (x >= _chartClip.left && x <= _chartClip.right) {
          canvas.drawLine(Offset(x, _chartClip.top), Offset(x, _chartClip.bottom), paint);
        }
      }
    }
  }

  void _drawLogMinorGridLinesY(Canvas canvas, List<double> ticks, double base, Paint paint) {
    final baseInt = base.toInt();
    for (int i = 0; i < ticks.length - 1; i++) {
      for (int m = 2; m < baseInt; m++) {
        final minorTick = ticks[i] * m;
        if (minorTick >= ticks[i + 1]) break;
        final y = _dataToScreenY(minorTick);
        if (y >= _chartClip.top && y <= _chartClip.bottom) {
          canvas.drawLine(Offset(_chartClip.left, y), Offset(_chartClip.right, y), paint);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Series rendering — type dispatcher
  // ---------------------------------------------------------------------------

  void _drawSeries(Canvas canvas, SeriesModel series) {
    switch (series.type) {
      case 'scatter':
      case 'xy_scatter':
        _drawScatterSeries(canvas, series);
        break;
      case 'mountain':
      case 'fast_mountain':
        _drawMountainSeries(canvas, series);
        break;
      case 'fast_line':
      default:
        _drawLineSeries(canvas, series);
        break;
    }
  }

  /// Get visible data range and optional decimation indices.
  /// Uses LTTB for line/mountain series, grid-bin for scatter.
  /// Returns null if insufficient visible points.
  _VisibleData? _getVisibleData(SeriesModel series, {int minPoints = 2}) {
    final data = series.data!;
    if (data.length < minPoints) return null;

    final xValues = data.xValues;
    final yValues = data.yValues;
    final int totalPoints = data.length;

    final visibleStart =
        (_lowerBound(xValues, _xMin, 0, totalPoints) - 1)
            .clamp(0, totalPoints - 1);
    final visibleEnd =
        (_upperBound(xValues, _xMax, 0, totalPoints) + 1)
            .clamp(0, totalPoints - 1);
    final visibleCount = visibleEnd - visibleStart + 1;
    if (visibleCount < minPoints) return null;

    final visibleX =
        Float64List.sublistView(xValues, visibleStart, visibleEnd + 1);
    final visibleY =
        Float64List.sublistView(yValues, visibleStart, visibleEnd + 1);

    final targetPoints = (_chartClip.width * 2).toInt().clamp(100, 10000);
    List<int>? indices;

    if (visibleCount > targetPoints) {
      final isScatter = series.type == 'scatter' || series.type == 'xy_scatter';
      if (isScatter) {
        final cellSize = math.max(series.pointMarkerSize, 4.0);
        indices = _gridBinDecimate(visibleX, visibleY, visibleCount, cellSize);
      } else {
        indices = _lttbDecimate(visibleX, visibleY, visibleCount, targetPoints);
      }
    }

    return _VisibleData(
      visibleX: visibleX,
      visibleY: visibleY,
      visibleCount: visibleCount,
      indices: indices,
      drawCount: indices?.length ?? visibleCount,
    );
  }

  /// Build a path through visible data points using the specified draw mode.
  Path _buildLinePath(_VisibleData vd, String drawMode) {
    final path = Path();
    if (vd.drawCount == 0) return path;

    final firstIdx = vd.indices?[0] ?? 0;
    path.moveTo(
      _dataToScreenX(vd.visibleX[firstIdx]),
      _dataToScreenY(vd.visibleY[firstIdx]),
    );

    switch (drawMode) {
      case 'step':
        // Step mode: horizontal then vertical (step-after)
        double prevY = _dataToScreenY(vd.visibleY[firstIdx]);
        for (int i = 1; i < vd.drawCount; i++) {
          final idx = vd.indices?[i] ?? i;
          final x = _dataToScreenX(vd.visibleX[idx]);
          final y = _dataToScreenY(vd.visibleY[idx]);
          path.lineTo(x, prevY); // horizontal to new x at old y
          path.lineTo(x, y);     // vertical to new y
          prevY = y;
        }
        break;

      case 'spline':
        // Catmull-Rom spline: convert to cubic Bezier segments
        // Collect screen points first
        final pts = <Offset>[];
        for (int i = 0; i < vd.drawCount; i++) {
          final idx = vd.indices?[i] ?? i;
          pts.add(Offset(
            _dataToScreenX(vd.visibleX[idx]),
            _dataToScreenY(vd.visibleY[idx]),
          ));
        }
        if (pts.length < 2) break;
        if (pts.length == 2) {
          path.lineTo(pts[1].dx, pts[1].dy);
          break;
        }
        // Catmull-Rom with tension 0.5 → cubic Bezier control points
        const double t = 0.5; // tension (0 = sharp, 1 = loose)
        for (int i = 0; i < pts.length - 1; i++) {
          final p0 = i > 0 ? pts[i - 1] : pts[i];
          final p1 = pts[i];
          final p2 = pts[i + 1];
          final p3 = i + 2 < pts.length ? pts[i + 2] : pts[i + 1];

          final cp1x = p1.dx + (p2.dx - p0.dx) / (6 * t);
          final cp1y = p1.dy + (p2.dy - p0.dy) / (6 * t);
          final cp2x = p2.dx - (p3.dx - p1.dx) / (6 * t);
          final cp2y = p2.dy - (p3.dy - p1.dy) / (6 * t);

          path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2.dx, p2.dy);
        }
        break;

      case 'linear':
      default:
        for (int i = 1; i < vd.drawCount; i++) {
          final idx = vd.indices?[i] ?? i;
          path.lineTo(
            _dataToScreenX(vd.visibleX[idx]),
            _dataToScreenY(vd.visibleY[idx]),
          );
        }
        break;
    }

    return path;
  }

  void _drawLineSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series);
    if (vd == null) return;

    final paint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = series.antiAliasing;

    final path = _buildLinePath(vd, series.drawMode);

    canvas.save();
    canvas.clipRect(_chartClip);
    canvas.drawPath(path, paint);

    // Draw point markers on top of line if configured
    if (series.pointMarkerType != 'none') {
      final markerFill = Paint()
        ..color = series.pointMarkerColor.withValues(alpha: series.opacity)
        ..style = PaintingStyle.fill
        ..isAntiAlias = series.antiAliasing;
      final markerStroke = Paint()
        ..color = series.strokeColor.withValues(alpha: series.opacity)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke
        ..isAntiAlias = series.antiAliasing;
      final radius = series.pointMarkerSize / 2;

      for (int i = 0; i < vd.drawCount; i++) {
        final idx = vd.indices?[i] ?? i;
        final cx = _dataToScreenX(vd.visibleX[idx]);
        final cy = _dataToScreenY(vd.visibleY[idx]);
        _drawPointMarker(canvas, cx, cy, radius, series.pointMarkerType,
            markerFill, markerStroke);
      }
    }

    canvas.restore();
  }

  void _drawScatterSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series, minPoints: 1);
    if (vd == null) return;

    final fillPaint = Paint()
      ..color = series.pointMarkerColor.withValues(alpha: series.opacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = series.antiAliasing;

    final strokePaint = series.strokeThickness > 0
        ? (Paint()
          ..color = series.strokeColor.withValues(alpha: series.opacity)
          ..strokeWidth = series.strokeThickness
          ..style = PaintingStyle.stroke
          ..isAntiAlias = series.antiAliasing)
        : null;

    final radius = series.pointMarkerSize / 2;
    final markerType = series.pointMarkerType == 'none'
        ? 'circle'
        : series.pointMarkerType;

    canvas.save();
    canvas.clipRect(_chartClip);
    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final cx = _dataToScreenX(vd.visibleX[idx]);
      final cy = _dataToScreenY(vd.visibleY[idx]);
      _drawPointMarker(canvas, cx, cy, radius, markerType,
          fillPaint, strokePaint);
    }
    canvas.restore();
  }

  void _drawMountainSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series);
    if (vd == null) return;

    final strokePaint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = series.antiAliasing;

    // Build line path
    final linePath = _buildLinePath(vd, series.drawMode);

    // Get first/last screen X for fill closure
    final firstIdx = vd.indices?[0] ?? 0;
    final lastIdx = vd.indices?[vd.drawCount - 1] ?? (vd.drawCount - 1);
    final firstScreenX = _dataToScreenX(vd.visibleX[firstIdx]);
    final lastScreenX = _dataToScreenX(vd.visibleX[lastIdx]);

    if (vd.drawCount == 0) return;

    // Build fill path: close the line down to zeroLineY baseline
    final baselineY = _dataToScreenY(series.zeroLineY);
    final fillPath = Path()..addPath(linePath, Offset.zero);
    fillPath.lineTo(lastScreenX, baselineY);
    fillPath.lineTo(firstScreenX, baselineY);
    fillPath.close();

    // Fill paint: gradient or solid
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = series.antiAliasing;

    if (series.gradientStartColor != null &&
        series.gradientEndColor != null) {
      // Preserve the alpha encoded in gradient colors; multiply by series opacity
      final startAlpha = series.gradientStartColor!.a * series.opacity;
      final endAlpha = series.gradientEndColor!.a * series.opacity;
      fillPaint.shader = ui.Gradient.linear(
        Offset(0, _plotArea.top),
        Offset(0, baselineY),
        [
          series.gradientStartColor!.withValues(alpha: startAlpha),
          series.gradientEndColor!.withValues(alpha: endAlpha),
        ],
      );
    } else if (series.fillColor != null) {
      final alpha = series.fillColor!.a * series.opacity;
      fillPaint.color = series.fillColor!.withValues(alpha: alpha);
    } else {
      fillPaint.color = series.strokeColor.withValues(alpha: 0.3 * series.opacity);
    }

    canvas.save();
    canvas.clipRect(_chartClip);
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(linePath, strokePaint);
    canvas.restore();
  }

  // ---------------------------------------------------------------------------
  // Point marker shapes (shared by scatter + line series with markers)
  // ---------------------------------------------------------------------------

  void _drawPointMarker(Canvas canvas, double cx, double cy, double radius,
      String markerType, Paint fillPaint, Paint? strokePaint) {
    switch (markerType) {
      case 'circle':
        canvas.drawCircle(Offset(cx, cy), radius, fillPaint);
        if (strokePaint != null) {
          canvas.drawCircle(Offset(cx, cy), radius, strokePaint);
        }
        break;
      case 'square':
        final rect = Rect.fromCenter(
            center: Offset(cx, cy),
            width: radius * 2,
            height: radius * 2);
        canvas.drawRect(rect, fillPaint);
        if (strokePaint != null) canvas.drawRect(rect, strokePaint);
        break;
      case 'triangle':
        final path = Path()
          ..moveTo(cx, cy - radius)
          ..lineTo(cx - radius, cy + radius)
          ..lineTo(cx + radius, cy + radius)
          ..close();
        canvas.drawPath(path, fillPaint);
        if (strokePaint != null) canvas.drawPath(path, strokePaint);
        break;
      case 'cross':
        final crossPaint = strokePaint ?? fillPaint;
        canvas.drawLine(
            Offset(cx - radius, cy), Offset(cx + radius, cy), crossPaint);
        canvas.drawLine(
            Offset(cx, cy - radius), Offset(cx, cy + radius), crossPaint);
        break;
      case 'ellipse':
        final rect = Rect.fromCenter(
            center: Offset(cx, cy),
            width: radius * 2,
            height: radius * 1.4);
        canvas.drawOval(rect, fillPaint);
        if (strokePaint != null) canvas.drawOval(rect, strokePaint);
        break;
    }
  }

  /// Binary search: first index where values[i] >= target.
  static int _lowerBound(Float64List values, double target,
      int start, int end) {
    while (start < end) {
      final mid = (start + end) >> 1;
      if (values[mid] < target) {
        start = mid + 1;
      } else {
        end = mid;
      }
    }
    return start;
  }

  /// Binary search: last index where values[i] <= target.
  static int _upperBound(Float64List values, double target,
      int start, int end) {
    while (start < end) {
      final mid = (start + end) >> 1;
      if (values[mid] <= target) {
        start = mid + 1;
      } else {
        end = mid;
      }
    }
    return start > 0 ? start - 1 : 0;
  }

  /// LTTB (Largest Triangle Three Buckets) downsampling algorithm.
  /// Reference: Steinarsson 2013 MSc thesis.
  List<int> _lttbDecimate(
    Float64List xValues,
    Float64List yValues,
    int dataLength,
    int targetCount,
  ) {
    if (targetCount >= dataLength || targetCount < 3) {
      return List<int>.generate(dataLength, (i) => i);
    }

    final result = List<int>.filled(targetCount, 0);
    result[0] = 0;
    result[targetCount - 1] = dataLength - 1;

    final double bucketSize = (dataLength - 2) / (targetCount - 2);
    int prevSelectedIndex = 0;

    for (int bucket = 1; bucket < targetCount - 1; bucket++) {
      final int bucketStart = ((bucket - 1) * bucketSize).floor() + 1;
      final int bucketEnd = (bucket * bucketSize).floor() + 1;
      final int actualEnd =
          bucketEnd < dataLength ? bucketEnd : dataLength - 1;

      final int nextBucketStart = (bucket * bucketSize).floor() + 1;
      final int nextBucketEnd = ((bucket + 1) * bucketSize).floor() + 1;
      final int actualNextEnd =
          nextBucketEnd < dataLength ? nextBucketEnd : dataLength - 1;

      double avgX = 0;
      double avgY = 0;
      int nextCount = 0;
      for (int j = nextBucketStart;
          j <= actualNextEnd && j < dataLength;
          j++) {
        avgX += xValues[j];
        avgY += yValues[j];
        nextCount++;
      }
      if (nextCount > 0) {
        avgX /= nextCount;
        avgY /= nextCount;
      }

      final double prevX = xValues[prevSelectedIndex];
      final double prevY = yValues[prevSelectedIndex];

      double maxArea = -1;
      int bestIndex = bucketStart;

      for (int j = bucketStart; j <= actualEnd && j < dataLength; j++) {
        final double area = ((prevX - avgX) * (yValues[j] - prevY) -
                (prevX - xValues[j]) * (avgY - prevY))
            .abs();
        if (area > maxArea) {
          maxArea = area;
          bestIndex = j;
        }
      }

      result[bucket] = bestIndex;
      prevSelectedIndex = bestIndex;
    }

    return result;
  }

  /// Grid-bin decimation for scatter series. Divides the plot area into
  /// pixel-sized grid cells and keeps the first point per cell. Preserves
  /// density distribution (unlike LTTB which biases toward outliers).
  List<int> _gridBinDecimate(
    Float64List xValues,
    Float64List yValues,
    int dataLength,
    double cellSize,
  ) {
    final xRange = _xMax - _xMin;
    final yRange = _yMax - _yMin;
    if (xRange <= 0 || yRange <= 0) {
      return List<int>.generate(dataLength, (i) => i);
    }

    // Number of grid cells in each dimension
    final int cols = (_plotArea.width / cellSize).ceil().clamp(1, 10000);
    final int rows = (_plotArea.height / cellSize).ceil().clamp(1, 10000);

    // Track which cells have been occupied
    final occupied = <int>{};
    final result = <int>[];

    for (int i = 0; i < dataLength; i++) {
      final nx = ((xValues[i] - _xMin) / xRange).clamp(0.0, 1.0);
      final ny = ((yValues[i] - _yMin) / yRange).clamp(0.0, 1.0);
      final col = (nx * (cols - 1)).round();
      final row = (ny * (rows - 1)).round();
      final key = row * cols + col;
      if (occupied.add(key)) {
        result.add(i);
      }
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // Annotations
  // ---------------------------------------------------------------------------

  void _drawAnnotations(Canvas canvas) {
    for (final ann in annotations) {
      final type = ann['type'] as String? ?? '';
      final opacity = (ann['opacity'] as num?)?.toDouble() ?? 1.0;

      switch (type) {
        case 'horizontal_line':
          _drawHorizontalLineAnnotation(canvas, ann, opacity);
          break;
        case 'vertical_line':
          _drawVerticalLineAnnotation(canvas, ann, opacity);
          break;
        case 'box':
          _drawBoxAnnotation(canvas, ann, opacity);
          break;
        case 'text':
          _drawTextAnnotation(canvas, ann, opacity);
          break;
      }
    }
  }

  void _drawHorizontalLineAnnotation(
      Canvas canvas, Map<String, dynamic> ann, double opacity) {
    final y = (ann['y'] as num?)?.toDouble();
    if (y == null) return;

    final screenY = _dataToScreenY(y);
    if (screenY < _chartClip.top || screenY > _chartClip.bottom) return;

    final color = SeriesModel.parseColorStatic(
        ann['color'] as String?, const Color(0xFFFFFF00));
    final thickness = (ann['thickness'] as num?)?.toDouble() ?? 1.0;

    canvas.drawLine(
      Offset(_chartClip.left, screenY),
      Offset(_chartClip.right, screenY),
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = thickness,
    );

    // Label
    final label = ann['label'] as String?;
    if (label != null && label.isNotEmpty) {
      final labelColor = SeriesModel.parseColorStatic(
          ann['label_color'] as String?, const Color(0xFFFFFFFF));
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: labelColor.withValues(alpha: opacity), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      // Paint label at left edge, slightly above the line
      tp.paint(canvas, Offset(_chartClip.left + 4, screenY - tp.height - 2));
    }
  }

  void _drawVerticalLineAnnotation(
      Canvas canvas, Map<String, dynamic> ann, double opacity) {
    final x = (ann['x'] as num?)?.toDouble();
    if (x == null) return;

    final screenX = _dataToScreenX(x);
    if (screenX < _chartClip.left || screenX > _chartClip.right) return;

    final color = SeriesModel.parseColorStatic(
        ann['color'] as String?, const Color(0xFFFFFF00));
    final thickness = (ann['thickness'] as num?)?.toDouble() ?? 1.0;

    canvas.drawLine(
      Offset(screenX, _chartClip.top),
      Offset(screenX, _chartClip.bottom),
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = thickness,
    );

    final label = ann['label'] as String?;
    if (label != null && label.isNotEmpty) {
      final labelColor = SeriesModel.parseColorStatic(
          ann['label_color'] as String?, const Color(0xFFFFFFFF));
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: labelColor.withValues(alpha: opacity), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(screenX + 4, _chartClip.top + 4));
    }
  }

  void _drawBoxAnnotation(
      Canvas canvas, Map<String, dynamic> ann, double opacity) {
    final xMin = (ann['x_min'] as num?)?.toDouble();
    final xMax = (ann['x_max'] as num?)?.toDouble();
    final yMin = (ann['y_min'] as num?)?.toDouble();
    final yMax = (ann['y_max'] as num?)?.toDouble();
    if (xMin == null || xMax == null || yMin == null || yMax == null) return;

    final left = _dataToScreenX(xMin);
    final right = _dataToScreenX(xMax);
    final top = _dataToScreenY(yMax);
    final bottom = _dataToScreenY(yMin);
    final rect = Rect.fromLTRB(left, top, right, bottom);

    final fillColor = SeriesModel.parseColorStatic(
        ann['fill_color'] as String?, const Color(0x334488FF));
    canvas.drawRect(rect, Paint()..color = fillColor.withValues(alpha: opacity));

    final borderColor = ann['border_color'] as String?;
    if (borderColor != null) {
      final bc = SeriesModel.parseColorStatic(borderColor, const Color(0xFF4488FF));
      final bt = (ann['border_thickness'] as num?)?.toDouble() ?? 1.0;
      canvas.drawRect(
        rect,
        Paint()
          ..color = bc.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = bt,
      );
    }
  }

  void _drawTextAnnotation(
      Canvas canvas, Map<String, dynamic> ann, double opacity) {
    final x = (ann['x'] as num?)?.toDouble();
    final y = (ann['y'] as num?)?.toDouble();
    final text = ann['text'] as String?;
    if (x == null || y == null || text == null || text.isEmpty) return;

    final screenX = _dataToScreenX(x);
    final screenY = _dataToScreenY(y);

    final color = SeriesModel.parseColorStatic(
        ann['color'] as String?, const Color(0xFFFFFFFF));
    final fontSize = (ann['font_size'] as num?)?.toDouble() ?? 12.0;

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color.withValues(alpha: opacity), fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();

    // Background box
    final bgColor = ann['background_color'] as String?;
    if (bgColor != null) {
      final bg = SeriesModel.parseColorStatic(bgColor, const Color(0x88000000));
      final bgRect = Rect.fromLTWH(
        screenX - 2, screenY - tp.height - 2,
        tp.width + 4, tp.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bgRect, const Radius.circular(2)),
        Paint()..color = bg.withValues(alpha: opacity),
      );
    }

    tp.paint(canvas, Offset(screenX, screenY - tp.height));
  }

  // ---------------------------------------------------------------------------
  // Legend
  // ---------------------------------------------------------------------------

  void _drawLegend(Canvas canvas, Size size) {
    legendHitRects.clear();

    const double swatchSize = 10.0;
    const double itemPadding = 6.0;
    const double boxPadding = 8.0;
    const double itemSpacing = 4.0;

    final textStyle = TextStyle(
      color: const Color(0xFFCCCCCC),
      fontSize: 11.0,
    );
    final dimTextStyle = TextStyle(
      color: const Color(0xFF666666),
      fontSize: 11.0,
    );

    // Measure all items first
    final labels = <String>[];
    final painters = <TextPainter>[];
    double maxItemWidth = 0;

    for (int i = 0; i < series.length; i++) {
      final s = series[i];
      final label = s.seriesName ?? s.seriesId ?? 'Series ${i + 1}';
      labels.add(label);
      final isHidden = hiddenSeriesIndices.contains(i);
      final tp = TextPainter(
        text: TextSpan(text: label, style: isHidden ? dimTextStyle : textStyle),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      painters.add(tp);
      final itemWidth = swatchSize + itemSpacing + tp.width;
      if (itemWidth > maxItemWidth) maxItemWidth = itemWidth;
    }

    final itemHeight = math.max(swatchSize, painters.first.height);
    final boxWidth = maxItemWidth + boxPadding * 2;
    final boxHeight = series.length * (itemHeight + itemPadding) - itemPadding + boxPadding * 2;

    // Position: top-left of plot area, offset slightly
    final boxLeft = _plotArea.left + 8;
    final boxTop = _plotArea.top + 8;
    final boxRect = Rect.fromLTWH(boxLeft, boxTop, boxWidth, boxHeight);

    // Semi-transparent background
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(4)),
      Paint()..color = const Color(0xCC1A1A2E),
    );
    // Border
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(4)),
      Paint()
        ..color = const Color(0xFF444466)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // Draw items
    for (int i = 0; i < series.length; i++) {
      final s = series[i];
      final isHidden = hiddenSeriesIndices.contains(i);
      final y = boxTop + boxPadding + i * (itemHeight + itemPadding);
      final swatchY = y + (itemHeight - swatchSize) / 2;

      // Color swatch
      final swatchColor = isHidden
          ? s.strokeColor.withValues(alpha: 0.3)
          : s.strokeColor;
      canvas.drawRect(
        Rect.fromLTWH(boxLeft + boxPadding, swatchY, swatchSize, swatchSize),
        Paint()..color = swatchColor,
      );

      // Label text
      final textX = boxLeft + boxPadding + swatchSize + itemSpacing;
      final textY = y + (itemHeight - painters[i].height) / 2;
      painters[i].paint(canvas, Offset(textX, textY));

      // Hit rect for click detection (full row)
      final hitRect = Rect.fromLTWH(boxLeft, y - itemPadding / 2,
          boxWidth, itemHeight + itemPadding);
      legendHitRects.add(hitRect);
    }
  }

  // ---------------------------------------------------------------------------
  // Undo / Redo buttons (top-right of plot area)
  // ---------------------------------------------------------------------------

  void _drawUndoRedo(Canvas canvas, Size size) {
    undoRedoHitRects.clear();
    if (!canUndo && !canRedo) return;

    const double btnSize = 22.0;
    const double btnGap = 4.0;
    const double margin = 8.0;
    const double iconPad = 4.0;

    // Position: top-right of plot area
    final rightEdge = _plotArea.right - margin;
    final topEdge = _plotArea.top + margin;

    // Draw redo first (rightmost), then undo to its left
    int btnCount = 0;
    if (canRedo) btnCount++;
    if (canUndo) btnCount++;

    double x = rightEdge - btnCount * btnSize - (btnCount - 1) * btnGap;

    // Undo button
    if (canUndo) {
      final rect = Rect.fromLTWH(x, topEdge, btnSize, btnSize);
      _drawZoomButton(canvas, rect, isUndo: true, active: true);
      undoRedoHitRects.add(rect); // index 0 = undo
      x += btnSize + btnGap;
    } else {
      undoRedoHitRects.add(Rect.zero); // placeholder
    }

    // Redo button
    if (canRedo) {
      final rect = Rect.fromLTWH(x, topEdge, btnSize, btnSize);
      _drawZoomButton(canvas, rect, isUndo: false, active: true);
      undoRedoHitRects.add(rect); // index 1 = redo
    } else {
      undoRedoHitRects.add(Rect.zero); // placeholder
    }
  }

  void _drawZoomButton(Canvas canvas, Rect rect,
      {required bool isUndo, required bool active}) {
    // Background pill
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = Color(active ? 0xAA1A1A2E : 0x551A1A2E),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()
        ..color = Color(active ? 0xFF555577 : 0xFF333355)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // Arrow icon — curved arrow pointing left (undo) or right (redo)
    final arrowPaint = Paint()
      ..color = Color(active ? 0xFFCCCCCC : 0xFF666666)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final r = rect.width * 0.25;

    if (isUndo) {
      // Curved arrow pointing left (counterclockwise)
      final arc = Path()
        ..addArc(Rect.fromCircle(center: Offset(cx + 1, cy), radius: r),
            -math.pi * 0.8, math.pi * 1.1);
      canvas.drawPath(arc, arrowPaint);
      // Arrowhead at start of arc
      final tipX = cx + 1 + r * math.cos(-math.pi * 0.8);
      final tipY = cy + r * math.sin(-math.pi * 0.8);
      canvas.drawLine(Offset(tipX, tipY), Offset(tipX - 3, tipY - 1), arrowPaint);
      canvas.drawLine(Offset(tipX, tipY), Offset(tipX + 1, tipY - 3.5), arrowPaint);
    } else {
      // Curved arrow pointing right (clockwise)
      final arc = Path()
        ..addArc(Rect.fromCircle(center: Offset(cx - 1, cy), radius: r),
            -math.pi * 0.2, -math.pi * 1.1);
      canvas.drawPath(arc, arrowPaint);
      // Arrowhead at start of arc
      final tipX = cx - 1 + r * math.cos(-math.pi * 0.2);
      final tipY = cy + r * math.sin(-math.pi * 0.2);
      canvas.drawLine(Offset(tipX, tipY), Offset(tipX + 3, tipY - 1), arrowPaint);
      canvas.drawLine(Offset(tipX, tipY), Offset(tipX - 1, tipY - 3.5), arrowPaint);
    }
  }

  // ---------------------------------------------------------------------------
  // Crosshair + Hover Tooltips
  // ---------------------------------------------------------------------------

  void _drawCrosshair(Canvas canvas, Size size) {
    final pos = hoverPosition!;
    if (!_plotArea.contains(pos)) return;

    final xIsLog = xAxis?.isLogarithmic == true;
    final yIsLog = yAxis?.isLogarithmic == true;
    final xLogBase = xAxis?.logarithmicBase ?? 10.0;

    // Vertical crosshair line
    final crosshairPaint = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(pos.dx, _plotArea.top),
      Offset(pos.dx, _plotArea.bottom),
      crosshairPaint,
    );

    // Horizontal crosshair line
    canvas.drawLine(
      Offset(_plotArea.left, pos.dy),
      Offset(_plotArea.right, pos.dy),
      crosshairPaint,
    );

    // Data X at cursor
    final double dataX;
    if (xIsLog) {
      final logBase = math.log(xLogBase);
      final logMin = math.log(_xMin.clamp(1e-100, double.infinity)) / logBase;
      final logMax = math.log(_xMax.clamp(1e-100, double.infinity)) / logBase;
      final ratio = (pos.dx - _plotArea.left) / _plotArea.width;
      dataX = math.pow(xLogBase, logMin + ratio * (logMax - logMin)).toDouble();
    } else {
      final ratio = (pos.dx - _plotArea.left) / _plotArea.width;
      dataX = _xMin + ratio * (_xMax - _xMin);
    }

    // X-value label pill on bottom axis
    final xLabel = xIsLog
        ? _formatLogNumber(dataX, xLogBase, labelFormat: xAxis?.labelFormat)
        : _formatNumber(dataX, labelFormat: xAxis?.labelFormat);
    final xLabelTp = TextPainter(
      text: TextSpan(
        text: xLabel,
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 10.0),
      ),
      textDirection: TextDirection.ltr,
    );
    xLabelTp.layout();
    final pillW = xLabelTp.width + 10;
    final pillH = xLabelTp.height + 6;
    final pillX = (pos.dx - pillW / 2).clamp(_plotArea.left, _plotArea.right - pillW);
    final pillY = _chartClip.bottom + 2;
    final pillRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(pillX, pillY, pillW, pillH),
      const Radius.circular(3),
    );
    canvas.drawRRect(pillRect, Paint()..color = const Color(0xFF2060BB));
    xLabelTp.paint(canvas, Offset(pillX + 5, pillY + 3));

    // Find nearest point per visible series and build tooltip entries
    final tooltipEntries = <_TooltipEntry>[];

    for (int i = 0; i < series.length; i++) {
      final s = series[i];
      if (!s.isVisible || hiddenSeriesIndices.contains(i) ||
          s.data == null || s.data!.length == 0) continue;

      final xValues = s.data!.xValues;
      final yValues = s.data!.yValues;
      final len = s.data!.length;

      // Binary search for nearest X
      int idx = _lowerBound(xValues, dataX, 0, len);
      if (idx >= len) idx = len - 1;
      if (idx > 0) {
        // Pick whichever neighbor is closer in data-X
        final dLeft = (dataX - xValues[idx - 1]).abs();
        final dRight = (dataX - xValues[idx]).abs();
        if (dLeft < dRight) idx = idx - 1;
      }

      final ptX = _dataToScreenX(xValues[idx]);
      final ptY = _dataToScreenY(yValues[idx]);

      // Only show if point is within plot area
      if (ptX < _plotArea.left - 5 || ptX > _plotArea.right + 5 ||
          ptY < _plotArea.top - 5 || ptY > _plotArea.bottom + 5) continue;

      // Draw marker dot at intersection
      canvas.drawCircle(
        Offset(ptX, ptY),
        4.0,
        Paint()..color = s.strokeColor,
      );
      canvas.drawCircle(
        Offset(ptX, ptY),
        4.0,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      final yLabel = yIsLog
          ? _formatLogNumber(yValues[idx], yAxis?.logarithmicBase ?? 10.0,
              labelFormat: yAxis?.labelFormat)
          : _formatNumber(yValues[idx], labelFormat: yAxis?.labelFormat);
      final name = s.seriesName ?? s.seriesId ?? 'Series ${i + 1}';
      tooltipEntries.add(_TooltipEntry(
        color: s.strokeColor,
        name: name,
        value: yLabel,
      ));
    }

    if (tooltipEntries.isEmpty) return;

    // Draw tooltip box
    const double tooltipPadding = 8.0;
    const double swatchSize = 8.0;
    const double spacing = 4.0;
    const double lineHeight = 16.0;

    // Measure tooltip content
    double maxNameWidth = 0;
    double maxValueWidth = 0;
    final namePainters = <TextPainter>[];
    final valuePainters = <TextPainter>[];

    for (final entry in tooltipEntries) {
      final nameTp = TextPainter(
        text: TextSpan(
          text: entry.name,
          style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 10.0),
        ),
        textDirection: TextDirection.ltr,
      );
      nameTp.layout();
      namePainters.add(nameTp);
      if (nameTp.width > maxNameWidth) maxNameWidth = nameTp.width;

      final valTp = TextPainter(
        text: TextSpan(
          text: entry.value,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 10.0,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      valTp.layout();
      valuePainters.add(valTp);
      if (valTp.width > maxValueWidth) maxValueWidth = valTp.width;
    }

    final tooltipWidth = tooltipPadding * 2 + swatchSize + spacing +
        maxNameWidth + spacing * 2 + maxValueWidth;
    final tooltipHeight = tooltipPadding * 2 +
        tooltipEntries.length * lineHeight - (lineHeight - 12);

    // Position tooltip near cursor, flip left/right based on space
    final bool flipRight = pos.dx + tooltipWidth + 16 > _plotArea.right;
    final tooltipX = flipRight
        ? pos.dx - tooltipWidth - 12
        : pos.dx + 12;
    final tooltipY = (pos.dy - tooltipHeight / 2)
        .clamp(_plotArea.top, _plotArea.bottom - tooltipHeight);

    final tooltipRect = Rect.fromLTWH(tooltipX, tooltipY, tooltipWidth, tooltipHeight);

    // Background
    canvas.drawRRect(
      RRect.fromRectAndRadius(tooltipRect, const Radius.circular(4)),
      Paint()..color = const Color(0xE6141428),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(tooltipRect, const Radius.circular(4)),
      Paint()
        ..color = const Color(0xFF555577)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // Draw entries
    for (int i = 0; i < tooltipEntries.length; i++) {
      final entry = tooltipEntries[i];
      final rowY = tooltipY + tooltipPadding + i * lineHeight;

      // Color swatch
      canvas.drawRect(
        Rect.fromLTWH(tooltipX + tooltipPadding, rowY + 1, swatchSize, swatchSize),
        Paint()..color = entry.color,
      );

      // Name
      namePainters[i].paint(canvas,
          Offset(tooltipX + tooltipPadding + swatchSize + spacing, rowY));

      // Value (right-aligned within its column)
      final valueX = tooltipX + tooltipPadding + swatchSize + spacing +
          maxNameWidth + spacing * 2;
      valuePainters[i].paint(canvas, Offset(valueX, rowY));
    }
  }

  void _drawXAxis(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = xAxis?.axisLineColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(_chartClip.left, _chartClip.bottom),
      Offset(_chartClip.right, _chartClip.bottom),
      axisPaint,
    );

    final xIsLog = xAxis?.isLogarithmic == true;
    final xLogBase = xAxis?.logarithmicBase ?? 10.0;
    final ticks = xIsLog
        ? calculateLogTicks(_xMin, _xMax, xLogBase)
        : calculateTicks(_xMin, _xMax, xAxis?.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = xAxis?.majorTickColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: xAxis?.axisLabelColor ?? const Color(0xFFCCCCCC),
      fontSize: xAxis?.axisLabelFontSize ?? 12.0,
    );

    // Minor ticks between major ticks
    if (showMinorGridLines && ticks.length >= 2) {
      final minorTickPaint = Paint()
        ..color = xAxis?.majorTickColor ?? const Color(0xFFAAAAAA)
        ..strokeWidth = 0.5;
      if (xIsLog) {
        final baseInt = xLogBase.toInt();
        for (int i = 0; i < ticks.length - 1; i++) {
          for (int m = 2; m < baseInt; m++) {
            final minorTick = ticks[i] * m;
            if (minorTick >= ticks[i + 1]) break;
            final x = _dataToScreenX(minorTick);
            if (x < _chartClip.left || x > _chartClip.right) continue;
            canvas.drawLine(
              Offset(x, _chartClip.bottom),
              Offset(x, _chartClip.bottom + 3),
              minorTickPaint,
            );
          }
        }
      } else {
        const int minorDivisions = 5;
        for (int i = 0; i < ticks.length - 1; i++) {
          final step = (ticks[i + 1] - ticks[i]) / minorDivisions;
          for (int j = 1; j < minorDivisions; j++) {
            final minorTick = ticks[i] + j * step;
            final x = _dataToScreenX(minorTick);
            if (x < _chartClip.left || x > _chartClip.right) continue;
            canvas.drawLine(
              Offset(x, _chartClip.bottom),
              Offset(x, _chartClip.bottom + 3),
              minorTickPaint,
            );
          }
        }
      }
    }

    for (final tick in ticks) {
      final x = _dataToScreenX(tick);
      if (x < _chartClip.left || x > _chartClip.right) continue;

      canvas.drawLine(
        Offset(x, _chartClip.bottom),
        Offset(x, _chartClip.bottom + 6),
        tickPaint,
      );

      final label = xIsLog
          ? _formatLogNumber(tick, xLogBase, labelFormat: xAxis?.labelFormat)
          : _formatNumber(tick, labelFormat: xAxis?.labelFormat);
      final textSpan = TextSpan(text: label, style: textStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, _chartClip.bottom + 8),
      );
    }

    if (xAxis?.axisTitle != null) {
      final titleStyle = TextStyle(
        color: xAxis?.axisTitleColor ?? const Color(0xFFCCCCCC),
        fontSize: xAxis?.axisTitleFontSize ?? 14.0,
      );
      final textSpan = TextSpan(text: xAxis!.axisTitle, style: titleStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          _chartClip.left + (_chartClip.width - textPainter.width) / 2,
          size.height - textPainter.height - 2,
        ),
      );
    }
  }

  void _drawYAxis(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = yAxis?.axisLineColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(_chartClip.right, _chartClip.top),
      Offset(_chartClip.right, _chartClip.bottom),
      axisPaint,
    );

    final yIsLog = yAxis?.isLogarithmic == true;
    final yLogBase = yAxis?.logarithmicBase ?? 10.0;
    final ticks = yIsLog
        ? calculateLogTicks(_yMin, _yMax, yLogBase)
        : calculateTicks(_yMin, _yMax, yAxis?.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = yAxis?.majorTickColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: yAxis?.axisLabelColor ?? const Color(0xFFCCCCCC),
      fontSize: yAxis?.axisLabelFontSize ?? 12.0,
    );

    // Minor ticks between major ticks
    if (showMinorGridLines && ticks.length >= 2) {
      final minorTickPaint = Paint()
        ..color = yAxis?.majorTickColor ?? const Color(0xFFAAAAAA)
        ..strokeWidth = 0.5;
      if (yIsLog) {
        final baseInt = yLogBase.toInt();
        for (int i = 0; i < ticks.length - 1; i++) {
          for (int m = 2; m < baseInt; m++) {
            final minorTick = ticks[i] * m;
            if (minorTick >= ticks[i + 1]) break;
            final y = _dataToScreenY(minorTick);
            if (y < _chartClip.top || y > _chartClip.bottom) continue;
            canvas.drawLine(
              Offset(_chartClip.right, y),
              Offset(_chartClip.right + 3, y),
              minorTickPaint,
            );
          }
        }
      } else {
        const int minorDivisions = 5;
        for (int i = 0; i < ticks.length - 1; i++) {
          final step = (ticks[i + 1] - ticks[i]) / minorDivisions;
          for (int j = 1; j < minorDivisions; j++) {
            final minorTick = ticks[i] + j * step;
            final y = _dataToScreenY(minorTick);
            if (y < _chartClip.top || y > _chartClip.bottom) continue;
            canvas.drawLine(
              Offset(_chartClip.right, y),
              Offset(_chartClip.right + 3, y),
              minorTickPaint,
            );
          }
        }
      }
    }

    for (final tick in ticks) {
      final y = _dataToScreenY(tick);
      if (y < _chartClip.top || y > _chartClip.bottom) continue;

      canvas.drawLine(
        Offset(_chartClip.right, y),
        Offset(_chartClip.right + 6, y),
        tickPaint,
      );

      final label = yIsLog
          ? _formatLogNumber(tick, yLogBase, labelFormat: yAxis?.labelFormat)
          : _formatNumber(tick, labelFormat: yAxis?.labelFormat);
      final textSpan = TextSpan(text: label, style: textStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(_chartClip.right + 8, y - textPainter.height / 2),
      );
    }

    if (yAxis?.axisTitle != null) {
      canvas.save();
      canvas.translate(
          size.width - 14, _chartClip.top + _chartClip.height / 2);
      canvas.rotate(math.pi / 2);

      final titleStyle = TextStyle(
        color: yAxis?.axisTitleColor ?? const Color(0xFFCCCCCC),
        fontSize: yAxis?.axisTitleFontSize ?? 14.0,
      );
      final textSpan = TextSpan(text: yAxis!.axisTitle, style: titleStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(-textPainter.width / 2, 0));

      canvas.restore();
    }
  }

  /// Try to apply a Python-style format string like "{:.2f}", "{:.3e}", "{:.4g}", "{:.1%}".
  /// Returns null if format is unrecognized (caller should fall back to default).
  static String? _applyLabelFormat(double value, String? format) {
    if (format == null || format.isEmpty) return null;

    // Match Python format specs: {:.Nf}, {:.Ne}, {:.Ng}, {:.N%}
    final match = RegExp(r'^\{:\.(\d+)([fFeEgG%])\}$').firstMatch(format);
    if (match == null) return null;

    final int precision = int.parse(match.group(1)!);
    final String specifier = match.group(2)!.toLowerCase();

    switch (specifier) {
      case 'f':
        return value.toStringAsFixed(precision);
      case 'e':
        return value.toStringAsExponential(precision);
      case 'g':
        // 'g' uses exponential if exponent < -4 or >= precision, else fixed
        if (value == 0) return value.toStringAsFixed(0);
        final exp = (math.log(value.abs()) / math.ln10).floor();
        if (exp < -4 || exp >= precision) {
          return value.toStringAsExponential(precision - 1);
        }
        return value.toStringAsPrecision(precision);
      case '%':
        return '${(value * 100).toStringAsFixed(precision)}%';
      default:
        return null;
    }
  }

  String _formatNumber(double value, {String? labelFormat}) {
    final formatted = _applyLabelFormat(value, labelFormat);
    if (formatted != null) return formatted;

    if (value.abs() >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value.abs() >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    } else {
      return value.toStringAsFixed(1);
    }
  }

  String _formatLogNumber(double value, double base, {String? labelFormat}) {
    final formatted = _applyLabelFormat(value, labelFormat);
    if (formatted != null) return formatted;

    if (value <= 0) return '0';
    // SciChart-style format: "Nx10^P" — e.g., "1x10²", "3x10²"
    final logBase = math.log(base);
    final logVal = math.log(value) / logBase;
    // Guard against floating point: log10(1000) = 2.9999... → round if very close
    int power;
    if ((logVal - logVal.roundToDouble()).abs() < 0.001) {
      power = logVal.round();
    } else {
      power = logVal.floor();
    }
    final coefficient = value / math.pow(base, power);
    final coeffRounded = coefficient.round();

    // Check if coefficient is close to an integer (1, 2, 3, etc.)
    if ((coefficient - coeffRounded).abs() < 0.1 && coeffRounded >= 1 && coeffRounded < base.toInt()) {
      if (base == 10.0) {
        final baseInt = base.toInt();
        if (power == 0) {
          return '$coeffRounded';
        } else if (power == 1) {
          return '${coeffRounded}x$baseInt';
        } else {
          // Unicode superscript digits
          final superPower = _toSuperscript(power);
          return '${coeffRounded}x$baseInt$superPower';
        }
      }
    }
    return _formatNumber(value);
  }

  static String _toSuperscript(int n) {
    const superDigits = {
      '0': '\u2070', '1': '\u00B9', '2': '\u00B2', '3': '\u00B3',
      '4': '\u2074', '5': '\u2075', '6': '\u2076', '7': '\u2077',
      '8': '\u2078', '9': '\u2079', '-': '\u207B',
    };
    return n.toString().split('').map((c) => superDigits[c] ?? c).join();
  }

  @override
  bool shouldRepaint(covariant ChartPainter oldDelegate) {
    return oldDelegate.xAxis != xAxis ||
        oldDelegate.yAxis != yAxis ||
        oldDelegate.gestureActive != gestureActive ||
        oldDelegate.series != series ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.showMajorGridLines != showMajorGridLines ||
        oldDelegate.showMinorGridLines != showMinorGridLines ||
        oldDelegate.majorGridLineColor != majorGridLineColor ||
        oldDelegate.minorGridLineColor != minorGridLineColor ||
        !_setEquals(oldDelegate.hiddenSeriesIndices, hiddenSeriesIndices) ||
        oldDelegate.hoverPosition != hoverPosition ||
        oldDelegate.rubberBandRect != rubberBandRect ||
        oldDelegate.annotations != annotations ||
        oldDelegate.canUndo != canUndo ||
        oldDelegate.canRedo != canRedo;
  }

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    for (final item in a) {
      if (!b.contains(item)) return false;
    }
    return true;
  }
}

/// Helper class for visible data range + decimation result.
class _VisibleData {
  final Float64List visibleX;
  final Float64List visibleY;
  final int visibleCount;
  final List<int>? indices;
  final int drawCount;

  _VisibleData({
    required this.visibleX,
    required this.visibleY,
    required this.visibleCount,
    required this.indices,
    required this.drawCount,
  });
}

/// Helper for crosshair tooltip entries.
class _TooltipEntry {
  final Color color;
  final String name;
  final String value;

  _TooltipEntry({required this.color, required this.name, required this.value});
}
