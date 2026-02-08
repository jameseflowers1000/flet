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

    // Cache key based on size + all computed ranges
    final cacheKey = '${size.width},${size.height},'
        '$_xMin,$_xMax,$_yMin,$_yMax,'
        '$_xDataMin,$_xDataMax,$_yDataMin,$_yDataMax';

    // --- Grid layer (always rebuild on range change — cheap line drawing) ---
    if (_gridCache == null || _gridCacheKey != cacheKey) {
      final gridRec = ui.PictureRecorder();
      final gridCanvas = Canvas(gridRec);
      try {
        _drawGridLines(gridCanvas, size);
      } catch (e) {
        debugPrint('[SuperPlot] _drawGridLines error: $e');
      }
      _gridCache = gridRec.endRecording();
      _gridCacheKey = cacheKey;
    }

    // --- Axes layer (always rebuild — correctness over performance) ---
    if (_axesCache == null || _axesCacheKey != cacheKey) {
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
      _axesCacheKey = cacheKey;
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
      double screenX, Rect plotArea, double xMin, double xMax) {
    final ratio = (screenX - plotArea.left) / plotArea.width;
    return xMin + ratio * (xMax - xMin);
  }

  /// Convert screen Y coordinate to data Y value (Y is inverted).
  static double screenToDataY(
      double screenY, Rect plotArea, double yMin, double yMax) {
    final ratio = (plotArea.bottom - screenY) / plotArea.height;
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
    final ratio = (dataX - _xMin) / (_xMax - _xMin);
    return _plotArea.left + ratio * _plotArea.width;
  }

  double _dataToScreenY(double dataY) {
    final ratio = (dataY - _yMin) / (_yMax - _yMin);
    return _plotArea.bottom - ratio * _plotArea.height;
  }

  void _drawGridLines(Canvas canvas, Size size) {
    final majorPaint = Paint()
      ..color = majorGridLineColor
      ..strokeWidth = 1.0;

    // Use visible range (_xMin/_xMax) for ticks, not data range (_xDataMin/_xDataMax).
    // This ensures grid lines cover the full visible area when zoomed out.
    final xTicks = calculateTicks(
        _xMin, _xMax, xAxis?.majorTickCount ?? 10);
    final yTicks = calculateTicks(
        _yMin, _yMax, yAxis?.majorTickCount ?? 10);

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

  void _drawSeries(Canvas canvas, SeriesModel series) {
    final data = series.data!;
    if (data.length < 2) return;

    final paint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = series.antiAliasing;

    final xValues = data.xValues;
    final yValues = data.yValues;
    final int totalPoints = data.length;

    // Pre-filter to visible X range (assumes sorted X data).
    // Pad by 1 on each side for line continuity at edges.
    final visibleStart =
        (_lowerBound(xValues, _xMin, 0, totalPoints) - 1)
            .clamp(0, totalPoints - 1);
    final visibleEnd =
        (_upperBound(xValues, _xMax, 0, totalPoints) + 1)
            .clamp(0, totalPoints - 1);
    final visibleCount = visibleEnd - visibleStart + 1;
    if (visibleCount < 2) return;

    // Zero-copy views of the visible subset.
    final visibleX =
        Float64List.sublistView(xValues, visibleStart, visibleEnd + 1);
    final visibleY =
        Float64List.sublistView(yValues, visibleStart, visibleEnd + 1);

    // Apply LTTB decimation when visible points exceed threshold.
    final targetPoints = (_chartClip.width * 2).toInt().clamp(100, 10000);
    final indices = visibleCount > targetPoints
        ? _lttbDecimate(visibleX, visibleY, visibleCount, targetPoints)
        : null;
    final int drawCount = indices?.length ?? visibleCount;

    final path = Path();
    bool started = false;

    for (int i = 0; i < drawCount; i++) {
      final idx = indices?[i] ?? i;
      final x = _dataToScreenX(visibleX[idx]);
      final y = _dataToScreenY(visibleY[idx]);

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
    canvas.restore();
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

    final ticks = calculateTicks(
        _xMin, _xMax, xAxis?.majorTickCount ?? 10);
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

      canvas.drawLine(
        Offset(x, _chartClip.bottom),
        Offset(x, _chartClip.bottom + 6),
        tickPaint,
      );

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

    final ticks = calculateTicks(
        _yMin, _yMax, yAxis?.majorTickCount ?? 10);
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

      canvas.drawLine(
        Offset(_chartClip.right, y),
        Offset(_chartClip.right + 6, y),
        tickPaint,
      );

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

  @override
  bool shouldRepaint(covariant ChartPainter oldDelegate) {
    return oldDelegate.xAxis?.visibleRangeMin != xAxis?.visibleRangeMin ||
        oldDelegate.xAxis?.visibleRangeMax != xAxis?.visibleRangeMax ||
        oldDelegate.yAxis?.visibleRangeMin != yAxis?.visibleRangeMin ||
        oldDelegate.yAxis?.visibleRangeMax != yAxis?.visibleRangeMax ||
        oldDelegate.gestureActive != gestureActive ||
        oldDelegate.series != series ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
