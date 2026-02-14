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

    // Draw: grid → series → axes
    canvas.drawPicture(_gridCache!);

    for (final s in series) {
      if (s.isVisible && s.data != null && s.data!.length > 0) {
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

  /// Get visible data range and optional LTTB decimation indices.
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
    final indices = visibleCount > targetPoints
        ? _lttbDecimate(visibleX, visibleY, visibleCount, targetPoints)
        : null;

    return _VisibleData(
      visibleX: visibleX,
      visibleY: visibleY,
      visibleCount: visibleCount,
      indices: indices,
      drawCount: indices?.length ?? visibleCount,
    );
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

    final path = Path();
    bool started = false;

    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final x = _dataToScreenX(vd.visibleX[idx]);
      final y = _dataToScreenY(vd.visibleY[idx]);

      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }

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
    final linePath = Path();
    double firstScreenX = 0;
    double lastScreenX = 0;
    bool started = false;

    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final x = _dataToScreenX(vd.visibleX[idx]);
      final y = _dataToScreenY(vd.visibleY[idx]);

      if (!started) {
        linePath.moveTo(x, y);
        firstScreenX = x;
        started = true;
      } else {
        linePath.lineTo(x, y);
      }
      lastScreenX = x;
    }

    if (!started) return;

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

      final label = xIsLog ? _formatLogNumber(tick, xLogBase) : _formatNumber(tick);
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

      final label = yIsLog ? _formatLogNumber(tick, yLogBase) : _formatNumber(tick);
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

  String _formatNumber(double value) {
    if (value.abs() >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value.abs() >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    } else {
      return value.toStringAsFixed(1);
    }
  }

  String _formatLogNumber(double value, double base) {
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
        oldDelegate.minorGridLineColor != minorGridLineColor;
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
