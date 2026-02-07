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

  // Computed during paint
  late Rect _plotArea;
  late Rect _chartClip;  // Visible chart area (for clipping)
  late double _xMin, _xMax, _yMin, _yMax;
  // Original ranges before grow-by (used for tick generation)
  late double _xDataMin, _xDataMax, _yDataMin, _yDataMax;

  // Layout constants (matching SciChart defaults)
  static const double _rightAxisWidth = 70.0;
  static const double _bottomAxisHeight = 52.0;

  // Cached pictures for grid and axes (expensive TextPainter work).
  // Invalidated when size or visible ranges change.
  // Split into two layers: grid (behind data) and axes (on top of data).
  static ui.Picture? _gridCache;
  static ui.Picture? _axesCache;
  static String _chromeCacheKey = '';

  ChartPainter({
    this.xAxis,
    this.yAxis,
    required this.series,
    required this.backgroundColor,
    required this.showMajorGridLines,
    required this.showMinorGridLines,
    required this.majorGridLineColor,
    required this.minorGridLineColor,
  });

  // Performance tracking - set _profileFrames > 0 to enable
  static int _frameCount = 0;
  static const int _profileFrames = 0; // Set to 10 to enable profiling

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();

    // Fill background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    // Chart clip rect: visible area excluding axis label areas
    _chartClip = Rect.fromLTRB(
      0, 0,
      size.width - _rightAxisWidth,
      size.height - _bottomAxisHeight,
    );

    final swRanges = Stopwatch()..start();
    try {
      _computeRanges();
    } catch (e) {
      debugPrint('SuperPlot _computeRanges error: $e');
      _xMin = 0; _xMax = 1; _yMin = 0; _yMax = 1;
      _xDataMin = 0; _xDataMax = 1; _yDataMin = 0; _yDataMax = 1;
    }
    swRanges.stop();

    final swPlot = Stopwatch()..start();
    try {
      _computePlotArea();
    } catch (e) {
      debugPrint('SuperPlot _computePlotArea error: $e');
      _plotArea = _chartClip;
    }
    swPlot.stop();

    // Build cache key from size + visible ranges
    final cacheKey = '${size.width},${size.height},'
        '$_xMin,$_xMax,$_yMin,$_yMax,'
        '$_xDataMin,$_xDataMax,$_yDataMin,$_yDataMax';
    final bool cacheHit = (_gridCache != null && _chromeCacheKey == cacheKey);

    // Build or replay cached grid + axes pictures
    final swChrome = Stopwatch()..start();
    if (!cacheHit) {
      // Record grid into its own Picture (drawn behind data)
      final gridRec = ui.PictureRecorder();
      final gridCanvas = Canvas(gridRec);
      try {
        _drawGridLines(gridCanvas, size);
      } catch (e) {
        print('SuperPlot _drawGridLines error: $e');
      }
      _gridCache = gridRec.endRecording();

      // Record axes into their own Picture (drawn on top of data)
      final axesRec = ui.PictureRecorder();
      final axesCanvas = Canvas(axesRec);
      try {
        _drawXAxis(axesCanvas, size);
      } catch (e) {
        debugPrint('SuperPlot _drawXAxis error: $e');
      }
      try {
        _drawYAxis(axesCanvas, size);
      } catch (e) {
        debugPrint('SuperPlot _drawYAxis error: $e');
      }
      _axesCache = axesRec.endRecording();

      _chromeCacheKey = cacheKey;
    }
    swChrome.stop();

    // Draw grid behind data
    canvas.drawPicture(_gridCache!);

    // Draw series data
    int totalPoints = 0;
    final swSeries = Stopwatch()..start();
    for (final s in series) {
      if (s.isVisible && s.data != null && s.data!.length > 0) {
        totalPoints += s.data!.length;
        try {
          _drawSeries(canvas, s);
        } catch (e) {
          debugPrint('SuperPlot _drawSeries error: $e');
        }
      }
    }
    swSeries.stop();

    // Draw axes on top of data
    canvas.drawPicture(_axesCache!);

    sw.stop();
    if (_frameCount < _profileFrames) {
      final targetPts = (_chartClip.width * 2).toInt().clamp(100, 10000);
      print('[PERF] frame=${_frameCount} total=${sw.elapsedMicroseconds}us '
          'ranges=${swRanges.elapsedMicroseconds}us '
          'plotArea=${swPlot.elapsedMicroseconds}us '
          'chrome=${swChrome.elapsedMicroseconds}us '
          'chromeHit=$cacheHit '
          'series=${swSeries.elapsedMicroseconds}us '
          'points=$totalPoints lttb=${totalPoints > targetPts ? "ON" : "OFF"}');
      _frameCount++;
    }
  }

  void _computeRanges() {
    // Start with axis-specified ranges or defaults
    _xMin = xAxis?.visibleRangeMin ?? double.infinity;
    _xMax = xAxis?.visibleRangeMax ?? double.negativeInfinity;
    _yMin = yAxis?.visibleRangeMin ?? double.infinity;
    _yMax = yAxis?.visibleRangeMax ?? double.negativeInfinity;

    // If auto-range, compute from data
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

    // Save original data ranges (before grow-by) for tick generation
    _xDataMin = _xMin.isFinite ? _xMin : 0;
    _xDataMax = _xMax.isFinite ? _xMax : 1;
    _yDataMin = _yMin.isFinite ? _yMin : 0;
    _yDataMax = _yMax.isFinite ? _yMax : 1;

    // Apply grow-by padding
    if (_xMin.isFinite && _xMax.isFinite) {
      final xRange = _xMax - _xMin;
      if (xRange > 0) {
        _xMin -= xRange * (xAxis?.growByMin ?? 0.1);
        _xMax += xRange * (xAxis?.growByMax ?? 0.1);
      } else {
        _xMin -= 1;
        _xMax += 1;
      }
    } else {
      _xMin = 0;
      _xMax = 1;
    }

    if (_yMin.isFinite && _yMax.isFinite) {
      final yRange = _yMax - _yMin;
      if (yRange > 0) {
        _yMin -= yRange * (yAxis?.growByMin ?? 0.1);
        _yMax += yRange * (yAxis?.growByMax ?? 0.1);
      } else {
        _yMin -= 1;
        _yMax += 1;
      }
    } else {
      _yMin = 0;
      _yMax = 1;
    }
  }

  void _computePlotArea() {
    // Compute ticks to determine gridline positions
    final xTicks = _calculateTicks(_xDataMin, _xDataMax, xAxis?.majorTickCount ?? 10);
    final yTicks = _calculateTicks(_yDataMin, _yDataMax, yAxis?.majorTickCount ?? 10);

    // SciChart uses asymmetric insets from chart edges to first/last gridlines.
    // Top/left: ~10px, bottom: ~3px (axis border), right: ~11px.
    const leftInset = 10.0;
    const topInset = 10.0;
    const rightInset = 11.0;
    const bottomInset = 3.0;

    if (xTicks.length >= 2 && yTicks.length >= 2) {
      final xTickSpan = xTicks.last - xTicks.first;
      final yTickSpan = yTicks.last - yTicks.first;

      // Pixel span available for gridlines
      final xPixelSpan = _chartClip.width - leftInset - rightInset;
      final yPixelSpan = _chartClip.height - topInset - bottomInset;

      // Pixels per data unit
      final xPPU = xTickSpan > 0 ? xPixelSpan / xTickSpan : 1.0;
      final yPPU = yTickSpan > 0 ? yPixelSpan / yTickSpan : 1.0;

      // Plot area: maps the full grow-by range
      // First X tick at chartClip.left + leftInset
      final plotLeft = _chartClip.left + leftInset - (xTicks.first - _xMin) * xPPU;
      final plotRight = plotLeft + (_xMax - _xMin) * xPPU;

      // Y is inverted: highest data value at top
      final plotTop = _chartClip.top + topInset - (_yMax - yTicks.last) * yPPU;
      final plotBottom = plotTop + (_yMax - _yMin) * yPPU;

      _plotArea = Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom);
    } else {
      _plotArea = _chartClip;
    }
  }

  double _dataToScreenX(double dataX) {
    final ratio = (dataX - _xMin) / (_xMax - _xMin);
    return _plotArea.left + ratio * _plotArea.width;
  }

  double _dataToScreenY(double dataY) {
    final ratio = (dataY - _yMin) / (_yMax - _yMin);
    // Y is inverted (screen Y increases downward)
    return _plotArea.bottom - ratio * _plotArea.height;
  }

  /// Simple grid that always works regardless of data
  void _drawSimpleGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0xFF00FF00)  // Bright green for visibility
      ..strokeWidth = 1.0;
    
    // Draw 10 vertical lines
    final chartWidth = size.width - _rightAxisWidth;
    final chartHeight = size.height - _bottomAxisHeight;
    for (int i = 0; i <= 10; i++) {
      final x = (chartWidth * i / 10);
      canvas.drawLine(Offset(x, 0), Offset(x, chartHeight), gridPaint);
    }
    // Draw 10 horizontal lines
    for (int i = 0; i <= 10; i++) {
      final y = (chartHeight * i / 10);
      canvas.drawLine(Offset(0, y), Offset(chartWidth, y), gridPaint);
    }
  }

  void _drawGridLines(Canvas canvas, Size size) {
    final majorPaint = Paint()
      ..color = majorGridLineColor
      ..strokeWidth = 1.0;

    final minorPaint = Paint()
      ..color = minorGridLineColor
      ..strokeWidth = 0.5;

    // Calculate nice tick values (using original data range, not grow-by range)
    final xTicks = _calculateTicks(_xDataMin, _xDataMax, xAxis?.majorTickCount ?? 10);
    final yTicks = _calculateTicks(_yDataMin, _yDataMax, yAxis?.majorTickCount ?? 10);

    // Draw vertical grid lines (X axis) - clipped to chart area
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
    }

    // Draw horizontal grid lines (Y axis) - clipped to chart area
    if (showMajorGridLines) {
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

  List<double> _calculateTicks(double min, double max, int targetCount) {
    if (!min.isFinite || !max.isFinite || min >= max) {
      return [0, 1];
    }

    final range = max - min;
    final rawStep = range / targetCount;

    // Round to nice number
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

  void _drawSeries(Canvas canvas, SeriesModel series) {
    final data = series.data!;
    if (data.length < 2) return;

    final paint = Paint()
      ..color = series.strokeColor.withOpacity(series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (series.antiAliasing) {
      paint.isAntiAlias = true;
    }

    // Apply LTTB decimation when point count exceeds threshold.
    // Target ~2x chart pixel width for high visual fidelity.
    final targetPoints = (_chartClip.width * 2).toInt().clamp(100, 10000);
    final xValues = data.xValues;
    final yValues = data.yValues;
    final int pointCount = data.length;

    // Get decimated indices (or null if no decimation needed)
    final lttbSw = Stopwatch()..start();
    final indices = pointCount > targetPoints
        ? _lttbDecimate(xValues, yValues, pointCount, targetPoints)
        : null;
    lttbSw.stop();
    final int drawCount = indices?.length ?? pointCount;

    // Build path from (decimated) data points
    final pathSw = Stopwatch()..start();
    final path = Path();
    bool started = false;

    for (int i = 0; i < drawCount; i++) {
      final idx = indices?[i] ?? i;
      final x = _dataToScreenX(xValues[idx]);
      final y = _dataToScreenY(yValues[idx]);

      // Skip points outside plot area (basic culling)
      if (x < _plotArea.left - 10 || x > _plotArea.right + 10) continue;

      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    pathSw.stop();

    // Clip to visible chart area and draw
    final drawSw = Stopwatch()..start();
    canvas.save();
    canvas.clipRect(_chartClip);
    canvas.drawPath(path, paint);
    canvas.restore();
    drawSw.stop();

    if (_frameCount < _profileFrames) {
      print('[PERF:series] pts=$pointCount drawn=$drawCount '
          'lttb=${lttbSw.elapsedMicroseconds}us '
          'path=${pathSw.elapsedMicroseconds}us '
          'draw=${drawSw.elapsedMicroseconds}us');
    }
  }

  /// LTTB (Largest Triangle Three Buckets) downsampling algorithm.
  ///
  /// Reduces [dataLength] points to [targetCount] while preserving visual shape.
  /// Returns a list of indices into the original data arrays.
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
    result[0] = 0; // Always keep first point
    result[targetCount - 1] = dataLength - 1; // Always keep last point

    // Bucket size for the middle points
    final double bucketSize = (dataLength - 2) / (targetCount - 2);

    int prevSelectedIndex = 0;

    for (int bucket = 1; bucket < targetCount - 1; bucket++) {
      // Current bucket range
      final int bucketStart = ((bucket - 1) * bucketSize).floor() + 1;
      final int bucketEnd = (bucket * bucketSize).floor() + 1;
      final int actualEnd = bucketEnd < dataLength ? bucketEnd : dataLength - 1;

      // Calculate average point of the NEXT bucket (for triangle area)
      final int nextBucketStart = (bucket * bucketSize).floor() + 1;
      final int nextBucketEnd = ((bucket + 1) * bucketSize).floor() + 1;
      final int actualNextEnd =
          nextBucketEnd < dataLength ? nextBucketEnd : dataLength - 1;

      double avgX = 0;
      double avgY = 0;
      int nextCount = 0;
      for (int j = nextBucketStart; j <= actualNextEnd && j < dataLength; j++) {
        avgX += xValues[j];
        avgY += yValues[j];
        nextCount++;
      }
      if (nextCount > 0) {
        avgX /= nextCount;
        avgY /= nextCount;
      }

      // Find the point in the current bucket that forms the largest triangle
      final double prevX = xValues[prevSelectedIndex];
      final double prevY = yValues[prevSelectedIndex];

      double maxArea = -1;
      int bestIndex = bucketStart;

      for (int j = bucketStart; j <= actualEnd && j < dataLength; j++) {
        // Triangle area = 0.5 * |x1(y2-y3) + x2(y3-y1) + x3(y1-y2)|
        // We skip the 0.5 since we're just comparing relative areas
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
    // Draw even without axis config using defaults

    final axisPaint = Paint()
      ..color = xAxis?.axisLineColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    // Draw axis line at bottom of chart area
    canvas.drawLine(
      Offset(_chartClip.left, _chartClip.bottom),
      Offset(_chartClip.right, _chartClip.bottom),
      axisPaint,
    );

    // Draw ticks and labels
    final ticks = _calculateTicks(_xDataMin, _xDataMax, xAxis?.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = xAxis?.majorTickColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: xAxis?.axisLabelColor ?? const Color(0xFFCCCCCC),
      fontSize: xAxis?.axisLabelFontSize ?? 12.0,
    );

    for (final tick in ticks) {
      final x = _dataToScreenX(tick);
      if (x < _chartClip.left || x > _chartClip.right) continue;

      // Draw tick
      canvas.drawLine(
        Offset(x, _chartClip.bottom),
        Offset(x, _chartClip.bottom + 6),
        tickPaint,
      );

      // Draw label
      final label = _formatNumber(tick);
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

    // Draw axis title centered below chart area
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
    // Draw even without axis config using defaults
    final axisPaint = Paint()
      ..color = yAxis?.axisLineColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    // Draw axis line at right edge of chart area
    canvas.drawLine(
      Offset(_chartClip.right, _chartClip.top),
      Offset(_chartClip.right, _chartClip.bottom),
      axisPaint,
    );

    // Draw ticks and labels
    final ticks = _calculateTicks(_yDataMin, _yDataMax, yAxis?.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = yAxis?.majorTickColor ?? const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: yAxis?.axisLabelColor ?? const Color(0xFFCCCCCC),
      fontSize: yAxis?.axisLabelFontSize ?? 12.0,
    );

    for (final tick in ticks) {
      final y = _dataToScreenY(tick);
      if (y < _chartClip.top || y > _chartClip.bottom) continue;

      // Draw tick
      canvas.drawLine(
        Offset(_chartClip.right, y),
        Offset(_chartClip.right + 6, y),
        tickPaint,
      );

      // Draw label
      final label = _formatNumber(tick);
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

    // Draw axis title (rotated) on right side
    if (yAxis?.axisTitle != null) {
      canvas.save();
      canvas.translate(size.width - 14, _chartClip.top + _chartClip.height / 2);
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
    // Always show 1 decimal place to match SciChart default formatting
    if (value.abs() >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    } else if (value.abs() >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    } else {
      return value.toStringAsFixed(1);
    }
  }

  @override
  bool shouldRepaint(covariant ChartPainter oldDelegate) {
    // For now, always repaint. Can optimize later.
    return true;
  }
}
