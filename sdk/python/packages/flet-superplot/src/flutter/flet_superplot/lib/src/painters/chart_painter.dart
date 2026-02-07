import 'dart:math' as math;
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

  @override
  void paint(Canvas canvas, Size size) {
    // Fill background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    // Compute data ranges (need these before calculating plot area)
    _computeRanges();

    // Chart clip rect: visible area excluding axis label areas
    _chartClip = Rect.fromLTRB(
      0, 0,
      size.width - _rightAxisWidth,
      size.height - _bottomAxisHeight,
    );

    // Compute plot area to match SciChart's gridline positioning.
    // SciChart extends the plot area beyond the canvas due to grow-by,
    // so gridlines for the data range appear inset from the chart edges.
    _computePlotArea();

    // Draw grid lines first (behind data)
    if (showMajorGridLines || showMinorGridLines) {
      _drawGridLines(canvas, size);
    }

    // Draw series data
    for (final s in series) {
      if (s.isVisible && s.data != null && s.data!.length > 0) {
        _drawSeries(canvas, s);
      }
    }

    // Draw axes on top
    _drawXAxis(canvas, size);
    _drawYAxis(canvas, size);
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
    niceStep *= magnitude as double;

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

    // Build path from data points
    final path = Path();
    bool started = false;

    for (int i = 0; i < data.length; i++) {
      final x = _dataToScreenX(data.xValues[i]);
      final y = _dataToScreenY(data.yValues[i]);

      // Skip points outside plot area (basic culling)
      if (x < _plotArea.left - 10 || x > _plotArea.right + 10) continue;

      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }

    // Clip to visible chart area and draw
    canvas.save();
    canvas.clipRect(_chartClip);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  void _drawXAxis(Canvas canvas, Size size) {
    if (xAxis == null) return;

    final axisPaint = Paint()
      ..color = xAxis!.axisLineColor
      ..strokeWidth = 1.0;

    // Draw axis line at bottom of chart area
    canvas.drawLine(
      Offset(_chartClip.left, _chartClip.bottom),
      Offset(_chartClip.right, _chartClip.bottom),
      axisPaint,
    );

    // Draw ticks and labels
    final ticks = _calculateTicks(_xDataMin, _xDataMax, xAxis!.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = xAxis!.majorTickColor
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: xAxis!.axisLabelColor,
      fontSize: xAxis!.axisLabelFontSize,
    );

    for (final tick in ticks) {
      final x = _dataToScreenX(tick);
      if (x < _chartClip.left || x > _chartClip.right) continue;

      // Draw tick
      if (xAxis!.drawMajorTicks) {
        canvas.drawLine(
          Offset(x, _chartClip.bottom),
          Offset(x, _chartClip.bottom + 6),
          tickPaint,
        );
      }

      // Draw label
      if (xAxis!.drawAxisLabels) {
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
    }

    // Draw axis title centered below chart area
    if (xAxis!.axisTitle != null) {
      final titleStyle = TextStyle(
        color: xAxis!.axisTitleColor,
        fontSize: xAxis!.axisTitleFontSize,
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
    if (yAxis == null) return;

    final axisPaint = Paint()
      ..color = yAxis!.axisLineColor
      ..strokeWidth = 1.0;

    // Draw axis line at right edge of chart area
    canvas.drawLine(
      Offset(_chartClip.right, _chartClip.top),
      Offset(_chartClip.right, _chartClip.bottom),
      axisPaint,
    );

    // Draw ticks and labels
    final ticks = _calculateTicks(_yDataMin, _yDataMax, yAxis!.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = yAxis!.majorTickColor
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: yAxis!.axisLabelColor,
      fontSize: yAxis!.axisLabelFontSize,
    );

    for (final tick in ticks) {
      final y = _dataToScreenY(tick);
      if (y < _chartClip.top || y > _chartClip.bottom) continue;

      // Draw tick to the right of axis line
      if (yAxis!.drawMajorTicks) {
        canvas.drawLine(
          Offset(_chartClip.right, y),
          Offset(_chartClip.right + 6, y),
          tickPaint,
        );
      }

      // Draw label to the right of tick
      if (yAxis!.drawAxisLabels) {
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
    }

    // Draw axis title (rotated) on right side
    if (yAxis!.axisTitle != null) {
      canvas.save();
      canvas.translate(size.width - 14, _chartClip.top + _chartClip.height / 2);
      canvas.rotate(math.pi / 2);

      final titleStyle = TextStyle(
        color: yAxis!.axisTitleColor,
        fontSize: yAxis!.axisTitleFontSize,
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
