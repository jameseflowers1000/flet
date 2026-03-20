import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';

import '../models/axis_model.dart';
import '../models/series_model.dart';

/// Main chart painter - renders axes, grid, and series data.
///
/// Uses CustomPainter for efficient GPU-accelerated rendering.
/// Designed for pixel-level compatibility with SciChart output.
class ChartPainter extends CustomPainter {
  final AxisModel? xAxis;
  final AxisModel? yAxis;
  final AxisModel? yAxis2; // Secondary Y axis (rendered on left side)
  final List<SeriesModel> series;
  final DataBufferStore dataBuffers;
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

  /// Stack offset tracking for stacked column/mountain series.
  /// Maps stackGroup → (xValue → cumulativeY).
  final Map<String, Map<double, double>> _stackOffsets = {};

  /// Whether undo/redo are available (controls button rendering).
  final bool canUndo;
  final bool canRedo;

  /// Hit rects for undo/redo buttons, populated during paint: [0]=undo, [1]=redo.
  final List<Rect> undoRedoHitRects;

  /// Mutable render state shared with draggable annotations and PaletteProvider.
  /// Keys are annotation IDs (e.g. "threshold"), values are current data values.
  final Map<String, dynamic> renderState;

  // Cached auto-range result from the last non-gesture paint.
  // InteractiveChart reads these on first zoom so its initial ranges
  // match exactly what the painter rendered — no coordinate jump.
  static double? lastAutoXMin, lastAutoXMax, lastAutoYMin, lastAutoYMax;

  /// Reset cached auto-range (call on double-tap reset or new data).
  static void resetAutoRange() {
    lastAutoXMin = null;
    lastAutoXMax = null;
    lastAutoYMin = null;
    lastAutoYMax = null;
  }

  // Computed during paint
  late Rect _plotArea;
  late Rect _chartClip;
  late double _xMin, _xMax, _yMin, _yMax;
  late double _xDataMin, _xDataMax, _yDataMin, _yDataMax;
  // Secondary Y axis ranges
  late double _y2Min, _y2Max;
  // Context flag: when true, _dataToScreenY uses Y2 axis ranges
  bool _useY2 = false;

  // Layout constants (matching SciChart defaults)
  static const double rightAxisWidth = 70.0;
  static const double leftAxisWidth = 70.0; // Used when yAxis2 is present
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
    this.yAxis2,
    required this.series,
    required this.dataBuffers,
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
    this.renderState = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fill background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    // Chart clip rect: visible area excluding axis label areas
    final hasLeftAxis = yAxis2 != null;
    _chartClip = Rect.fromLTRB(
      hasLeftAxis ? leftAxisWidth : 0,
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

    // Cache auto-range result when not gesturing so InteractiveChart
    // can adopt the exact same ranges on first zoom interaction.
    if (!gestureActive) {
      lastAutoXMin = _xMin;
      lastAutoXMax = _xMax;
      lastAutoYMin = _yMin;
      lastAutoYMax = _yMax;
    }

    try {
      _computePlotArea();
    } catch (e) {
      debugPrint('[SuperPlot] _computePlotArea error: $e');
      _plotArea = _chartClip;
    }

    // Cache keys include all properties that affect each layer's rendering
    final rangeKey = '${size.width},${size.height},'
        '$_xMin,$_xMax,$_yMin,$_yMax,$_y2Min,$_y2Max,'
        '$_xDataMin,$_xDataMax,$_yDataMin,$_yDataMax';
    final gridCacheKey = '$rangeKey,'
        '$showMajorGridLines,$showMinorGridLines,'
        '${majorGridLineColor.value},${minorGridLineColor.value}';
    final axesCacheKey = '$rangeKey,'
        '${xAxis?.axisTitle},${yAxis?.axisTitle},${yAxis2?.axisTitle},'
        '${xAxis?.labelFormat},${yAxis?.labelFormat},${yAxis2?.labelFormat},'
        '${xAxis?.type},${yAxis?.type},${yAxis2?.type}';

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
      if (yAxis2 != null) {
        try {
          _drawLeftYAxis(axesCanvas, size);
        } catch (e) {
          debugPrint('[SuperPlot] _drawLeftYAxis error: $e');
        }
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

    _stackOffsets.clear(); // Reset stack tracking for this paint cycle

    for (int i = 0; i < series.length; i++) {
      final s = series[i];
      if (!s.isVisible || hiddenSeriesIndices.contains(i)) continue;
      // Check if series has data (embedded or named buffer)
      final hasData = s.usesNamedBuffers
          ? (s.xCol != null && dataBuffers.containsKey(s.xCol!))
          : (s.data != null && s.data!.length > 0);
      if (!hasData) continue;
      try {
        _drawSeries(canvas, s);
      } catch (e) {
        debugPrint('[SuperPlot] _drawSeries error: $e');
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
  static Rect computePlotArea({required Size size, bool hasLeftAxis = false}) {
    return Rect.fromLTRB(
      (hasLeftAxis ? leftAxisWidth : 0) + leftInset,
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

  /// Calculate nice tick values for a datetime axis (epoch-millisecond values).
  /// Auto-selects step size (minutes, hours, days, months, years) based on range.
  static List<double> calculateDateTimeTicks(double minMs, double maxMs, int targetCount) {
    final rangeMs = maxMs - minMs;
    if (rangeMs <= 0) return [minMs];

    // Choose step size based on range
    const minute = 60 * 1000.0;
    const hour = 60 * minute;
    const day = 24 * hour;
    const month = 30 * day;
    const year = 365 * day;

    // Nice step intervals
    final steps = [
      minute, 2 * minute, 5 * minute, 10 * minute, 15 * minute, 30 * minute,
      hour, 2 * hour, 4 * hour, 6 * hour, 12 * hour,
      day, 2 * day, 7 * day, 14 * day,
      month, 2 * month, 3 * month, 6 * month,
      year, 2 * year, 5 * year, 10 * year,
    ];

    final idealStep = rangeMs / targetCount;
    double step = steps.last;
    for (final s in steps) {
      if (s >= idealStep * 0.5) {
        step = s;
        break;
      }
    }

    final firstTick = (minMs / step).ceil() * step;
    final ticks = <double>[];
    for (double t = firstTick; t <= maxMs; t += step) {
      ticks.add(t);
    }
    return ticks;
  }

  /// Format an epoch-millisecond value as a human-readable date/time label.
  /// Auto-selects format based on the visible range.
  static String formatDateTime(double epochMs, double rangeMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs.toInt(), isUtc: true);
    const hour = 3600 * 1000.0;
    const day = 24 * hour;
    const month = 30 * day;
    const year = 365 * day;

    if (rangeMs < 2 * hour) {
      // Minutes: "14:30"
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (rangeMs < 3 * day) {
      // Hours: "Mar 5 14:00"
      return '${_monthAbbr(dt.month)} ${dt.day} ${dt.hour.toString().padLeft(2, '0')}:00';
    } else if (rangeMs < 3 * month) {
      // Days: "Mar 5"
      return '${_monthAbbr(dt.month)} ${dt.day}';
    } else if (rangeMs < 3 * year) {
      // Months: "Mar 2024"
      return '${_monthAbbr(dt.month)} ${dt.year}';
    } else {
      // Years: "2024"
      return '${dt.year}';
    }
  }

  static String _monthAbbr(int month) {
    const names = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return names[(month - 1).clamp(0, 11)];
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
        if (s.usesNamedBuffers) {
          // Named buffer path
          if (xAutoRange && s.xCol != null && dataBuffers.containsKey(s.xCol!)) {
            final (dataXMin, dataXMax) = dataBuffers.range(s.xCol!);
            if (dataXMin < _xMin) _xMin = dataXMin;
            if (dataXMax > _xMax) _xMax = dataXMax;
          }
          if (yAutoRange) {
            final (dataYMin, dataYMax) = s.yRangeFromBuffers(dataBuffers);
            if (dataYMin < _yMin) _yMin = dataYMin;
            if (dataYMax > _yMax) _yMax = dataYMax;
          }
        } else if (s.data != null && s.data!.isNotEmpty) {
          // Embedded data path
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

      // Account for cumulative stacking in Y range.
      // Per-series Y ranges don't reflect stacked totals (e.g., 3 series each
      // with yMax=80 stack to 240). Compute cumulative Y per stack group.
      if (yAutoRange) {
        final Map<String, Map<double, double>> stackAccum = {};
        for (final s in series) {
          if (s.stackGroup == null) continue;
          final offsets = stackAccum.putIfAbsent(s.stackGroup!, () => {});
          Float64List? xData, yData;
          if (s.usesNamedBuffers) {
            xData = s.xCol != null ? dataBuffers[s.xCol!] : null;
            yData = s.yCol != null ? dataBuffers[s.yCol!] : null;
          } else if (s.data != null && s.data!.isNotEmpty) {
            xData = s.data!.xValues;
            yData = s.data!.yValues;
          }
          if (xData == null || yData == null) continue;
          final count = xData.length < yData.length ? xData.length : yData.length;
          for (int i = 0; i < count; i++) {
            final base = offsets[xData[i]] ?? 0.0;
            final top = base + yData[i];
            offsets[xData[i]] = top;
            if (top > _yMax) _yMax = top;
            if (top < _yMin) _yMin = top;
          }
        }

        // Waterfall series: running cumulative total determines Y range
        for (final s in series) {
          if (s.type != 'waterfall') continue;
          Float64List? yData;
          if (s.usesNamedBuffers) {
            yData = s.yCol != null ? dataBuffers[s.yCol!] : null;
          } else if (s.data != null && s.data!.isNotEmpty) {
            yData = s.data!.yValues;
          }
          if (yData == null) continue;
          double cumulative = 0;
          for (int i = 0; i < yData.length; i++) {
            cumulative += yData[i];
            if (cumulative > _yMax) _yMax = cumulative;
            if (cumulative < _yMin) _yMin = cumulative;
          }
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

    // Compute secondary Y axis range (for series bound to "y1")
    _y2Min = yAxis2?.visibleRangeMin ?? double.infinity;
    _y2Max = yAxis2?.visibleRangeMax ?? double.negativeInfinity;
    if (yAxis2 != null && yAxis2!.autoRange != 'never') {
      for (final s in series) {
        if (s.yAxisId != yAxis2!.id) continue;
        if (s.usesNamedBuffers) {
          final (dataYMin, dataYMax) = s.yRangeFromBuffers(dataBuffers);
          if (dataYMin < _y2Min) _y2Min = dataYMin;
          if (dataYMax > _y2Max) _y2Max = dataYMax;
        } else if (s.data != null && s.data!.isNotEmpty) {
          final (dataYMin, dataYMax) = s.data!.yRange;
          if (dataYMin < _y2Min) _y2Min = dataYMin;
          if (dataYMax > _y2Max) _y2Max = dataYMax;
        }
      }
    }
    if (_y2Min.isFinite && _y2Max.isFinite) {
      if (yAxis2?.isLogarithmic == true) {
        final base = yAxis2!.logarithmicBase ?? 10.0;
        if (_y2Min > 0 && _y2Max > _y2Min) {
          _y2Min = _y2Min / math.pow(base, yAxis2!.growByMin);
          _y2Max = _y2Max * math.pow(base, yAxis2!.growByMax);
        } else {
          _y2Min = 0.1;
          _y2Max = 10;
        }
      } else {
        final y2Range = _y2Max - _y2Min;
        if (y2Range > 0) {
          _y2Min -= y2Range * (yAxis2?.growByMin ?? 0.1);
          _y2Max += y2Range * (yAxis2?.growByMax ?? 0.1);
        } else {
          _y2Min -= 1;
          _y2Max += 1;
        }
      }
    } else {
      _y2Min = yAxis2?.isLogarithmic == true ? 0.1 : 0;
      _y2Max = yAxis2?.isLogarithmic == true ? 10 : 1;
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
    // When _useY2 is set, use secondary Y axis ranges
    if (_useY2 && yAxis2 != null) {
      if (yAxis2!.isLogarithmic) {
        final base = yAxis2!.logarithmicBase ?? 10.0;
        final logBase = math.log(base);
        final logMin = math.log(_y2Min.clamp(1e-100, double.infinity)) / logBase;
        final logMax = math.log(_y2Max.clamp(1e-100, double.infinity)) / logBase;
        final logVal = math.log(dataY.clamp(1e-100, double.infinity)) / logBase;
        final ratio = (logVal - logMin) / (logMax - logMin);
        return _plotArea.bottom - ratio * _plotArea.height;
      }
      final ratio = (dataY - _y2Min) / (_y2Max - _y2Min);
      return _plotArea.bottom - ratio * _plotArea.height;
    }
    // Primary Y axis
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

  /// Data-to-screen Y for the secondary (left) Y axis (used by _drawLeftYAxis).
  double _dataToScreenY2(double dataY) {
    if (yAxis2?.isLogarithmic == true) {
      final base = yAxis2!.logarithmicBase ?? 10.0;
      final logBase = math.log(base);
      final logMin = math.log(_y2Min.clamp(1e-100, double.infinity)) / logBase;
      final logMax = math.log(_y2Max.clamp(1e-100, double.infinity)) / logBase;
      final logVal = math.log(dataY.clamp(1e-100, double.infinity)) / logBase;
      final ratio = (logVal - logMin) / (logMax - logMin);
      return _plotArea.bottom - ratio * _plotArea.height;
    }
    final ratio = (dataY - _y2Min) / (_y2Max - _y2Min);
    return _plotArea.bottom - ratio * _plotArea.height;
  }

  void _drawGridLines(Canvas canvas, Size size) {
    final majorPaint = Paint()
      ..color = majorGridLineColor
      ..strokeWidth = 1.0;

    final xIsLog = xAxis?.isLogarithmic == true;
    final xIsDateTime = xAxis?.isDateTime == true;
    final yIsLog = yAxis?.isLogarithmic == true;
    final xLogBase = xAxis?.logarithmicBase ?? 10.0;
    final yLogBase = yAxis?.logarithmicBase ?? 10.0;

    final xTicks = xIsLog
        ? calculateLogTicks(_xMin, _xMax, xLogBase)
        : xIsDateTime
            ? calculateDateTimeTicks(_xMin, _xMax, xAxis?.majorTickCount ?? 8)
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

  // ---------------------------------------------------------------------------
  // PaletteProvider: per-point color formula evaluation
  // ---------------------------------------------------------------------------

  /// Evaluate a color_formula f-string for a specific data point.
  /// Returns null on error or if MicroPython is not ready.
  Color? _evalColorFormula(String formula, double x, double y, int index) {
    if (!MicroPythonService.isReady) return null;
    try {
      final ctx = <String, dynamic>{
        ...renderState,
        'x': x,
        'y': y,
        'index': index,
      };
      final result = MicroPythonService.fmt(formula, ctx);
      if (result == null || result.isEmpty) return null;
      return SeriesModel.parseColorStatic(result, Colors.grey);
    } catch (e) {
      return null;
    }
  }

  void _drawSeries(Canvas canvas, SeriesModel series) {
    // Set Y axis context for this series (dual axis support)
    _useY2 = yAxis2 != null && series.yAxisId == yAxis2!.id;

    // For named-buffer series, resolve data before drawing
    if (series.usesNamedBuffers && series.data == null) {
      // Types that access dataBuffers directly (multi-column data)
      // don't need resolveData — pass through to their specialized painters
      if (series.type == 'candlestick' || series.type == 'band' ||
          series.type == 'bubble' || series.type == 'error_bar' ||
          series.type == 'box_plot') {
        _dispatchDraw(canvas, series);
        return;
      }
      // XY-based types: resolve named buffers into DataPoints
      final resolved = series.resolveData(dataBuffers);
      if (resolved == null || resolved.isEmpty) return;
      // Create a temporary series with resolved data for existing drawing methods
      final resolvedSeries = SeriesModel(
        type: series.type,
        seriesId: series.seriesId,
        seriesName: series.seriesName,
        data: resolved,
        strokeColor: series.strokeColor,
        strokeThickness: series.strokeThickness,
        drawMode: series.drawMode,
        antiAliasing: series.antiAliasing,
        pointMarkerType: series.pointMarkerType,
        pointMarkerSize: series.pointMarkerSize,
        pointMarkerColor: series.pointMarkerColor,
        opacity: series.opacity,
        isVisible: series.isVisible,
        tooltipFormat: series.tooltipFormat,
        fillColor: series.fillColor,
        gradientStartColor: series.gradientStartColor,
        gradientEndColor: series.gradientEndColor,
        zeroLineY: series.zeroLineY,
        xCol: series.xCol,
        yCol: series.yCol,
        openCol: series.openCol,
        highCol: series.highCol,
        lowCol: series.lowCol,
        closeCol: series.closeCol,
        yHighCol: series.yHighCol,
        yLowCol: series.yLowCol,
        barWidth: series.barWidth,
        upColor: series.upColor,
        downColor: series.downColor,
        wickColor: series.wickColor,
        bodyWidth: series.bodyWidth,
        borderColor: series.borderColor,
        borderWidth: series.borderWidth,
        colorFormula: series.colorFormula,
        yAxisId: series.yAxisId,
        stackGroup: series.stackGroup,
        dashPattern: series.dashPattern,
        sizeCol: series.sizeCol,
        errorHighCol: series.errorHighCol,
        errorLowCol: series.errorLowCol,
        capWidth: series.capWidth,
        minCol: series.minCol,
        q1Col: series.q1Col,
        medianCol: series.medianCol,
        q3Col: series.q3Col,
        maxCol: series.maxCol,
        medianColor: series.medianColor,
        totalColor: series.totalColor,
      );
      _dispatchDraw(canvas, resolvedSeries);
    } else {
      _dispatchDraw(canvas, series);
    }
  }

  void _dispatchDraw(Canvas canvas, SeriesModel series) {
    switch (series.type) {
      case 'scatter':
      case 'xy_scatter':
        _drawScatterSeries(canvas, series);
        break;
      case 'mountain':
      case 'fast_mountain':
        _drawMountainSeries(canvas, series);
        break;
      case 'column':
        _drawColumnSeries(canvas, series);
        break;
      case 'candlestick':
        _drawCandlestickSeries(canvas, series);
        break;
      case 'band':
        _drawBandSeries(canvas, series);
        break;
      case 'impulse':
        _drawImpulseSeries(canvas, series);
        break;
      case 'bubble':
        _drawBubbleSeries(canvas, series);
        break;
      case 'error_bar':
        _drawErrorBarSeries(canvas, series);
        break;
      case 'box_plot':
        _drawBoxPlotSeries(canvas, series);
        break;
      case 'waterfall':
        _drawWaterfallSeries(canvas, series);
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
  /// Convert a solid path to a dashed path using the given pattern.
  Path _dashPath(Path source, List<double> pattern) {
    final result = Path();
    for (final metric in source.computeMetrics()) {
      double distance = 0.0;
      int patIdx = 0;
      bool draw = true;
      while (distance < metric.length) {
        final len = pattern[patIdx % pattern.length];
        final nextDist = distance + len;
        if (draw) {
          result.addPath(
            metric.extractPath(distance, nextDist.clamp(0, metric.length)),
            Offset.zero,
          );
        }
        distance = nextDist;
        draw = !draw;
        patIdx++;
      }
    }
    return result;
  }

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

    var path = _buildLinePath(vd, series.drawMode);

    // Apply dash pattern if specified
    if (series.dashPattern != null && series.dashPattern!.isNotEmpty) {
      path = _dashPath(path, series.dashPattern!);
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
      final hasColorFormula = series.colorFormula != null;

      for (int i = 0; i < vd.drawCount; i++) {
        final idx = vd.indices?[i] ?? i;
        final xVal = vd.visibleX[idx];
        final yVal = vd.visibleY[idx];
        final cx = _dataToScreenX(xVal);
        final cy = _dataToScreenY(yVal);

        Paint effectiveFill = markerFill;
        if (hasColorFormula) {
          final c = _evalColorFormula(series.colorFormula!, xVal, yVal, idx);
          if (c != null) {
            effectiveFill = Paint()
              ..color = c.withValues(alpha: series.opacity)
              ..style = PaintingStyle.fill
              ..isAntiAlias = series.antiAliasing;
          }
        }
        _drawPointMarker(canvas, cx, cy, radius, series.pointMarkerType,
            effectiveFill, markerStroke);
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

    final hasColorFormula = series.colorFormula != null;
    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final xVal = vd.visibleX[idx];
      final yVal = vd.visibleY[idx];
      final cx = _dataToScreenX(xVal);
      final cy = _dataToScreenY(yVal);

      Paint effectiveFill = fillPaint;
      if (hasColorFormula) {
        final c = _evalColorFormula(series.colorFormula!, xVal, yVal, idx);
        if (c != null) {
          effectiveFill = Paint()
            ..color = c.withValues(alpha: series.opacity)
            ..style = PaintingStyle.fill
            ..isAntiAlias = series.antiAliasing;
        }
      }
      _drawPointMarker(canvas, cx, cy, radius, markerType,
          effectiveFill, strokePaint);
    }
    canvas.restore();
  }

  void _drawMountainSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series);
    if (vd == null) return;

    // Stack group support: offset Y values by cumulative stack
    final isStacked = series.stackGroup != null;
    Map<double, double>? groupOffsets;
    Float64List? baselineYValues; // per-point baseline for stacked fill
    if (isStacked) {
      groupOffsets = _stackOffsets.putIfAbsent(series.stackGroup!, () => {});
      baselineYValues = Float64List(vd.drawCount);
      // Offset visible Y values and record baselines
      for (int i = 0; i < vd.drawCount; i++) {
        final idx = vd.indices?[i] ?? i;
        final xVal = vd.visibleX[idx];
        final base = groupOffsets![xVal] ?? series.zeroLineY;
        baselineYValues[i] = base;
        final newY = base + vd.visibleY[idx];
        vd.visibleY[idx] = newY;
        groupOffsets[xVal] = newY;
      }
    }

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

    // Build fill path
    final fillPath = Path()..addPath(linePath, Offset.zero);
    if (isStacked && baselineYValues != null) {
      // Close down to previous stack's top (not flat baseline)
      for (int i = vd.drawCount - 1; i >= 0; i--) {
        final idx = vd.indices?[i] ?? i;
        fillPath.lineTo(
          _dataToScreenX(vd.visibleX[idx]),
          _dataToScreenY(baselineYValues[i]),
        );
      }
    } else {
      final baselineY = _dataToScreenY(series.zeroLineY);
      fillPath.lineTo(lastScreenX, baselineY);
      fillPath.lineTo(firstScreenX, baselineY);
    }
    fillPath.close();

    // Fill paint: gradient or solid
    final gradBaseY = _dataToScreenY(series.zeroLineY);
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
        Offset(0, gradBaseY),
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
  // Column series rendering
  // ---------------------------------------------------------------------------

  void _drawImpulseSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series);
    if (vd == null || vd.drawCount < 1) return;

    final baselineY = _dataToScreenY(series.zeroLineY);
    final paint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke;

    canvas.save();
    canvas.clipRect(_chartClip);

    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final cx = _dataToScreenX(vd.visibleX[idx]);
      final cy = _dataToScreenY(vd.visibleY[idx]);
      canvas.drawLine(Offset(cx, baselineY), Offset(cx, cy), paint);
      // Small circle at the tip
      canvas.drawCircle(Offset(cx, cy), 3.0, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
    }

    canvas.restore();
  }

  void _drawBubbleSeries(Canvas canvas, SeriesModel series) {
    final xBuf = dataBuffers[series.xCol ?? ''];
    final yBuf = dataBuffers[series.yCol ?? ''];
    final sizeBuf = dataBuffers[series.sizeCol ?? ''];
    if (xBuf == null || yBuf == null || sizeBuf == null) return;

    final count = [xBuf.length, yBuf.length, sizeBuf.length].reduce(math.min);
    if (count == 0) return;

    // Normalize sizes: find min/max of size column, map to 4-40px radius
    double sizeMin = sizeBuf[0], sizeMax = sizeBuf[0];
    for (int i = 1; i < count; i++) {
      if (sizeBuf[i] < sizeMin) sizeMin = sizeBuf[i];
      if (sizeBuf[i] > sizeMax) sizeMax = sizeBuf[i];
    }
    final sizeRange = sizeMax - sizeMin;

    final paint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = series.strokeColor.withValues(alpha: math.min(series.opacity + 0.3, 1.0))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.save();
    canvas.clipRect(_chartClip);

    for (int i = 0; i < count; i++) {
      final cx = _dataToScreenX(xBuf[i]);
      final cy = _dataToScreenY(yBuf[i]);
      final normSize = sizeRange > 0 ? (sizeBuf[i] - sizeMin) / sizeRange : 0.5;
      final radius = 4.0 + normSize * 36.0;
      canvas.drawCircle(Offset(cx, cy), radius, paint);
      canvas.drawCircle(Offset(cx, cy), radius, strokePaint);
    }

    canvas.restore();
  }

  void _drawErrorBarSeries(Canvas canvas, SeriesModel series) {
    final xBuf = dataBuffers[series.xCol ?? ''];
    final yBuf = dataBuffers[series.yCol ?? ''];
    final errHighBuf = dataBuffers[series.errorHighCol ?? ''];
    final errLowBuf = dataBuffers[series.errorLowCol ?? ''];
    if (xBuf == null || yBuf == null || errHighBuf == null || errLowBuf == null) return;

    final count = [xBuf.length, yBuf.length, errHighBuf.length, errLowBuf.length].reduce(math.min);
    if (count == 0) return;

    final paint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke;
    final capHalf = series.capWidth / 2;

    canvas.save();
    canvas.clipRect(_chartClip);

    for (int i = 0; i < count; i++) {
      final cx = _dataToScreenX(xBuf[i]);
      final cy = _dataToScreenY(yBuf[i]);
      final highY = _dataToScreenY(yBuf[i] + errHighBuf[i]);
      final lowY = _dataToScreenY(yBuf[i] - errLowBuf[i]);

      // Vertical whisker
      canvas.drawLine(Offset(cx, highY), Offset(cx, lowY), paint);
      // Top cap
      canvas.drawLine(Offset(cx - capHalf, highY), Offset(cx + capHalf, highY), paint);
      // Bottom cap
      canvas.drawLine(Offset(cx - capHalf, lowY), Offset(cx + capHalf, lowY), paint);
      // Center dot
      canvas.drawCircle(Offset(cx, cy), 3.0, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
    }

    canvas.restore();
  }

  void _drawBoxPlotSeries(Canvas canvas, SeriesModel series) {
    final xBuf = dataBuffers[series.xCol ?? ''];
    final minBuf = dataBuffers[series.minCol ?? ''];
    final q1Buf = dataBuffers[series.q1Col ?? ''];
    final medBuf = dataBuffers[series.medianCol ?? ''];
    final q3Buf = dataBuffers[series.q3Col ?? ''];
    final maxBuf = dataBuffers[series.maxCol ?? ''];
    if (xBuf == null || minBuf == null || q1Buf == null ||
        medBuf == null || q3Buf == null || maxBuf == null) return;

    final count = [xBuf.length, minBuf.length, q1Buf.length,
                   medBuf.length, q3Buf.length, maxBuf.length].reduce(math.min);
    if (count == 0) return;

    final fillPaint = Paint()
      ..color = (series.fillColor ?? series.strokeColor.withValues(alpha: 0.25))
          .withValues(alpha: series.opacity)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.strokeThickness
      ..style = PaintingStyle.stroke;
    final medianPaint = Paint()
      ..color = (series.medianColor ?? Colors.white).withValues(alpha: series.opacity)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // Box width based on data spacing
    double spacing = 1.0;
    if (count >= 2) {
      double minSpacing = double.infinity;
      for (int i = 1; i < count && i < 50; i++) {
        final d = (xBuf[i] - xBuf[i - 1]).abs();
        if (d > 0 && d < minSpacing) minSpacing = d;
      }
      if (minSpacing.isFinite) spacing = minSpacing;
    }
    final halfBox = (_dataToScreenX(_xMin + spacing * 0.6) - _dataToScreenX(_xMin)) / 2;
    final capHalf = halfBox * 0.6;

    canvas.save();
    canvas.clipRect(_chartClip);

    for (int i = 0; i < count; i++) {
      final cx = _dataToScreenX(xBuf[i]);
      final minY = _dataToScreenY(minBuf[i]);
      final q1Y = _dataToScreenY(q1Buf[i]);
      final medY = _dataToScreenY(medBuf[i]);
      final q3Y = _dataToScreenY(q3Buf[i]);
      final maxY = _dataToScreenY(maxBuf[i]);

      // Whiskers
      canvas.drawLine(Offset(cx, maxY), Offset(cx, q3Y), strokePaint);
      canvas.drawLine(Offset(cx, q1Y), Offset(cx, minY), strokePaint);
      // Caps
      canvas.drawLine(Offset(cx - capHalf, maxY), Offset(cx + capHalf, maxY), strokePaint);
      canvas.drawLine(Offset(cx - capHalf, minY), Offset(cx + capHalf, minY), strokePaint);
      // Box (Q1 to Q3)
      final boxRect = Rect.fromLTRB(cx - halfBox, q3Y, cx + halfBox, q1Y);
      canvas.drawRect(boxRect, fillPaint);
      canvas.drawRect(boxRect, strokePaint);
      // Median line
      canvas.drawLine(Offset(cx - halfBox, medY), Offset(cx + halfBox, medY), medianPaint);
    }

    canvas.restore();
  }

  void _drawWaterfallSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series);
    if (vd == null || vd.drawCount < 1) return;

    final upColor = (series.upColor ?? const Color(0xFF26A69A))
        .withValues(alpha: series.opacity);
    final downColor = (series.downColor ?? const Color(0xFFEF5350))
        .withValues(alpha: series.opacity);
    final totalColor = (series.totalColor ?? series.strokeColor)
        .withValues(alpha: series.opacity);
    final upPaint = Paint()..color = upColor..style = PaintingStyle.fill;
    final downPaint = Paint()..color = downColor..style = PaintingStyle.fill;
    final totalPaint = Paint()..color = totalColor..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = series.strokeColor.withValues(alpha: series.opacity * 0.6)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Bar width
    final xValues = vd.visibleX;
    double spacing = 1.0;
    if (vd.visibleCount >= 2) {
      double minSpacing = double.infinity;
      for (int i = 1; i < vd.visibleCount && i < 100; i++) {
        final d = (xValues[i] - xValues[i - 1]).abs();
        if (d > 0 && d < minSpacing) minSpacing = d;
      }
      if (minSpacing.isFinite) spacing = minSpacing;
    }
    final halfBar = (_dataToScreenX(_xMin + spacing * 0.7) - _dataToScreenX(_xMin)) / 2;

    canvas.save();
    canvas.clipRect(_chartClip);

    double cumulative = 0;
    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final cx = _dataToScreenX(vd.visibleX[idx]);
      final value = vd.visibleY[idx];
      final prevCum = cumulative;
      cumulative += value;

      final topY = _dataToScreenY(cumulative);
      final bottomY = _dataToScreenY(prevCum);

      final rect = Rect.fromLTRB(
        cx - halfBar,
        topY < bottomY ? topY : bottomY,
        cx + halfBar,
        topY < bottomY ? bottomY : topY,
      );

      final paint = value >= 0 ? upPaint : downPaint;
      canvas.drawRect(rect, paint);
      canvas.drawRect(rect, strokePaint);
    }

    canvas.restore();
  }

  void _drawColumnSeries(Canvas canvas, SeriesModel series) {
    final vd = _getVisibleData(series);
    if (vd == null || vd.drawCount < 1) return;

    // Determine bar width from data spacing
    final xValues = vd.visibleX;
    double spacing = 1.0;
    if (vd.visibleCount >= 2) {
      // Use minimum spacing between consecutive points
      double minSpacing = double.infinity;
      for (int i = 1; i < vd.visibleCount && i < 100; i++) {
        final d = (xValues[i] - xValues[i - 1]).abs();
        if (d > 0 && d < minSpacing) minSpacing = d;
      }
      if (minSpacing.isFinite) spacing = minSpacing;
    }

    final barWidthData = spacing * series.barWidth;
    final halfBarScreen = (_dataToScreenX(_xMin + barWidthData) - _dataToScreenX(_xMin)) / 2;

    final fillColor = series.fillColor ?? series.strokeColor;
    final fillPaint = Paint()
      ..color = fillColor.withValues(alpha: series.opacity)
      ..style = PaintingStyle.fill;

    final strokePaint = series.strokeColor != fillColor
        ? (Paint()
          ..color = series.strokeColor.withValues(alpha: series.opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0)
        : null;

    // Stack group support
    final isStacked = series.stackGroup != null;
    Map<double, double>? groupOffsets;
    if (isStacked) {
      groupOffsets = _stackOffsets.putIfAbsent(series.stackGroup!, () => {});
    }

    canvas.save();
    canvas.clipRect(_chartClip);

    final hasColorFormula = series.colorFormula != null;
    for (int i = 0; i < vd.drawCount; i++) {
      final idx = vd.indices?[i] ?? i;
      final xVal = vd.visibleX[idx];
      final yVal = vd.visibleY[idx];
      final cx = _dataToScreenX(xVal);

      double baseY, topVal;
      if (isStacked) {
        baseY = groupOffsets![xVal] ?? series.zeroLineY;
        topVal = baseY + yVal;
        groupOffsets[xVal] = topVal;
      } else {
        baseY = series.zeroLineY;
        topVal = yVal;
      }

      final top = _dataToScreenY(topVal);
      final bottom = _dataToScreenY(baseY);

      // Bar rect: from baseline to value
      final rect = Rect.fromLTRB(
        cx - halfBarScreen,
        top < bottom ? top : bottom,
        cx + halfBarScreen,
        top < bottom ? bottom : top,
      );

      Paint effectiveFill = fillPaint;
      if (hasColorFormula) {
        final c = _evalColorFormula(series.colorFormula!, xVal, yVal, idx);
        if (c != null) {
          effectiveFill = Paint()
            ..color = c.withValues(alpha: series.opacity)
            ..style = PaintingStyle.fill;
        }
      }
      canvas.drawRect(rect, effectiveFill);
      if (strokePaint != null) canvas.drawRect(rect, strokePaint);
    }

    canvas.restore();
  }

  // ---------------------------------------------------------------------------
  // Candlestick series rendering
  // ---------------------------------------------------------------------------

  void _drawCandlestickSeries(Canvas canvas, SeriesModel series) {
    // Candlestick requires OHLC data from named buffers
    if (!series.usesNamedBuffers) return;
    final xBuf = series.xCol != null ? dataBuffers[series.xCol!] : null;
    final openBuf = series.openCol != null ? dataBuffers[series.openCol!] : null;
    final highBuf = series.highCol != null ? dataBuffers[series.highCol!] : null;
    final lowBuf = series.lowCol != null ? dataBuffers[series.lowCol!] : null;
    final closeBuf = series.closeCol != null ? dataBuffers[series.closeCol!] : null;
    if (xBuf == null || openBuf == null || highBuf == null ||
        lowBuf == null || closeBuf == null) return;

    final count = [xBuf.length, openBuf.length, highBuf.length,
                   lowBuf.length, closeBuf.length].reduce(math.min);
    if (count == 0) return;

    // Determine body width from data spacing
    double spacing = 1.0;
    if (count >= 2) {
      double minSpacing = double.infinity;
      for (int i = 1; i < count && i < 100; i++) {
        final d = (xBuf[i] - xBuf[i - 1]).abs();
        if (d > 0 && d < minSpacing) minSpacing = d;
      }
      if (minSpacing.isFinite) spacing = minSpacing;
    }

    final bodyWidthData = spacing * series.bodyWidth;
    final halfBodyScreen = (_dataToScreenX(_xMin + bodyWidthData) - _dataToScreenX(_xMin)) / 2;

    final upColor = series.upColor ?? const Color(0xFF26A69A);
    final downColor = series.downColor ?? const Color(0xFFEF5350);

    canvas.save();
    canvas.clipRect(_chartClip);

    for (int i = 0; i < count; i++) {
      final x = xBuf[i];
      if (x < _xMin || x > _xMax) continue;

      final open = openBuf[i];
      final high = highBuf[i];
      final low = lowBuf[i];
      final close = closeBuf[i];
      final isUp = close >= open;

      final cx = _dataToScreenX(x);
      final screenHigh = _dataToScreenY(high);
      final screenLow = _dataToScreenY(low);
      final screenOpen = _dataToScreenY(open);
      final screenClose = _dataToScreenY(close);

      Color color = isUp ? upColor : downColor;
      // PaletteProvider override: color_formula gets x, y=close, index
      if (series.colorFormula != null) {
        final c = _evalColorFormula(series.colorFormula!, x, close, i);
        if (c != null) color = c;
      }
      final wickColor = series.wickColor ?? color;

      // Wick: thin vertical line from high to low
      canvas.drawLine(
        Offset(cx, screenHigh),
        Offset(cx, screenLow),
        Paint()
          ..color = wickColor.withValues(alpha: series.opacity)
          ..strokeWidth = 1.0,
      );

      // Body: filled rect from open to close
      final bodyTop = math.min(screenOpen, screenClose);
      final bodyBottom = math.max(screenOpen, screenClose);
      final bodyRect = Rect.fromLTRB(
        cx - halfBodyScreen,
        bodyTop,
        cx + halfBodyScreen,
        // Ensure minimum visible body height
        math.max(bodyBottom, bodyTop + 1),
      );

      canvas.drawRect(
        bodyRect,
        Paint()
          ..color = color.withValues(alpha: series.opacity)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        bodyRect,
        Paint()
          ..color = color.withValues(alpha: series.opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }

    canvas.restore();
  }

  // ---------------------------------------------------------------------------
  // Band series rendering
  // ---------------------------------------------------------------------------

  void _drawBandSeries(Canvas canvas, SeriesModel series) {
    // Band requires x, y_high, y_low from named buffers
    if (!series.usesNamedBuffers) return;
    final xBuf = series.xCol != null ? dataBuffers[series.xCol!] : null;
    final yHighBuf = series.yHighCol != null ? dataBuffers[series.yHighCol!] : null;
    final yLowBuf = series.yLowCol != null ? dataBuffers[series.yLowCol!] : null;
    if (xBuf == null || yHighBuf == null || yLowBuf == null) return;

    final count = [xBuf.length, yHighBuf.length, yLowBuf.length].reduce(math.min);
    if (count < 2) return;

    // Find visible range
    final visibleStart = (_lowerBound(xBuf, _xMin, 0, count) - 1).clamp(0, count - 1);
    final visibleEnd = (_upperBound(xBuf, _xMax, 0, count) + 1).clamp(0, count - 1);
    final visibleCount = visibleEnd - visibleStart + 1;
    if (visibleCount < 2) return;

    // Apply LTTB decimation to both curves simultaneously
    // Use the high curve for LTTB selection (preserves same indices for both)
    final visibleX = Float64List.sublistView(xBuf, visibleStart, visibleEnd + 1);
    final visibleYHigh = Float64List.sublistView(yHighBuf, visibleStart, visibleEnd + 1);
    final visibleYLow = Float64List.sublistView(yLowBuf, visibleStart, visibleEnd + 1);

    final targetPoints = (_chartClip.width * 2).toInt().clamp(100, 10000);
    List<int>? indices;
    if (visibleCount > targetPoints) {
      indices = _lttbDecimate(visibleX, visibleYHigh, visibleCount, targetPoints);
    }
    final drawCount = indices?.length ?? visibleCount;

    // Build closed path: forward along y_high, backward along y_low
    final fillPath = Path();

    // Forward along upper bound
    int firstIdx = indices?[0] ?? 0;
    fillPath.moveTo(
      _dataToScreenX(visibleX[firstIdx]),
      _dataToScreenY(visibleYHigh[firstIdx]),
    );
    for (int i = 1; i < drawCount; i++) {
      final idx = indices?[i] ?? i;
      fillPath.lineTo(
        _dataToScreenX(visibleX[idx]),
        _dataToScreenY(visibleYHigh[idx]),
      );
    }

    // Backward along lower bound
    for (int i = drawCount - 1; i >= 0; i--) {
      final idx = indices?[i] ?? i;
      fillPath.lineTo(
        _dataToScreenX(visibleX[idx]),
        _dataToScreenY(visibleYLow[idx]),
      );
    }
    fillPath.close();

    // Fill
    final fillColor = series.fillColor ?? series.strokeColor.withValues(alpha: 0.2);
    final fillPaint = Paint()
      ..color = fillColor.withValues(alpha: fillColor.a * series.opacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = series.antiAliasing;

    canvas.save();
    canvas.clipRect(_chartClip);
    canvas.drawPath(fillPath, fillPaint);

    // Stroke upper and lower edges
    final borderColor = series.borderColor ?? series.strokeColor;
    final strokePaint = Paint()
      ..color = borderColor.withValues(alpha: series.opacity)
      ..strokeWidth = series.borderWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = series.antiAliasing;

    // Upper edge
    final upperPath = Path();
    upperPath.moveTo(
      _dataToScreenX(visibleX[indices?[0] ?? 0]),
      _dataToScreenY(visibleYHigh[indices?[0] ?? 0]),
    );
    for (int i = 1; i < drawCount; i++) {
      final idx = indices?[i] ?? i;
      upperPath.lineTo(
        _dataToScreenX(visibleX[idx]),
        _dataToScreenY(visibleYHigh[idx]),
      );
    }
    canvas.drawPath(upperPath, strokePaint);

    // Lower edge
    final lowerPath = Path();
    lowerPath.moveTo(
      _dataToScreenX(visibleX[indices?[0] ?? 0]),
      _dataToScreenY(visibleYLow[indices?[0] ?? 0]),
    );
    for (int i = 1; i < drawCount; i++) {
      final idx = indices?[i] ?? i;
      lowerPath.lineTo(
        _dataToScreenX(visibleX[idx]),
        _dataToScreenY(visibleYLow[idx]),
      );
    }
    canvas.drawPath(lowerPath, strokePaint);

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
        case 'draggable_hline':
          _drawDraggableHLineAnnotation(canvas, ann, opacity);
          break;
        case 'draggable_vline':
          _drawDraggableVLineAnnotation(canvas, ann, opacity);
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

  void _drawDraggableHLineAnnotation(
      Canvas canvas, Map<String, dynamic> ann, double opacity) {
    final id = ann['id'] as String?;
    if (id == null) return;

    // Read live value from renderState (updated during drag)
    final y = (renderState[id] as num?)?.toDouble()
        ?? (ann['y'] as num?)?.toDouble();
    if (y == null) return;

    final screenY = _dataToScreenY(y);
    if (screenY < _chartClip.top - 20 || screenY > _chartClip.bottom + 20) return;

    final color = SeriesModel.parseColorStatic(
        ann['color'] as String?, const Color(0xFFFFFF00));
    final thickness = (ann['thickness'] as num?)?.toDouble() ?? 1.5;

    // Thicker line for draggable affordance
    canvas.drawLine(
      Offset(_chartClip.left, screenY),
      Offset(_chartClip.right, screenY),
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = thickness,
    );

    // Grab handle: small circles at left edge
    final handlePaint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(_chartClip.left + 8, screenY), 3.5, handlePaint);
    canvas.drawCircle(Offset(_chartClip.left + 18, screenY), 3.5, handlePaint);

    // Label with current value
    final label = ann['label'] as String?;
    final labelText = label ?? '$id: ${y.toStringAsFixed(1)}';
    final tp = TextPainter(
      text: TextSpan(
        text: labelText,
        style: TextStyle(
          color: color.withValues(alpha: opacity),
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(_chartClip.left + 28, screenY - tp.height - 2));
  }

  void _drawDraggableVLineAnnotation(
      Canvas canvas, Map<String, dynamic> ann, double opacity) {
    final id = ann['id'] as String?;
    if (id == null) return;

    final x = (renderState[id] as num?)?.toDouble()
        ?? (ann['x'] as num?)?.toDouble();
    if (x == null) return;

    final screenX = _dataToScreenX(x);
    if (screenX < _chartClip.left - 20 || screenX > _chartClip.right + 20) return;

    final color = SeriesModel.parseColorStatic(
        ann['color'] as String?, const Color(0xFFFFFF00));
    final thickness = (ann['thickness'] as num?)?.toDouble() ?? 1.5;

    canvas.drawLine(
      Offset(screenX, _chartClip.top),
      Offset(screenX, _chartClip.bottom),
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = thickness,
    );

    // Grab handle: small circles at top
    final handlePaint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(screenX, _chartClip.top + 8), 3.5, handlePaint);
    canvas.drawCircle(Offset(screenX, _chartClip.top + 18), 3.5, handlePaint);

    final label = ann['label'] as String?;
    final labelText = label ?? '$id: ${x.toStringAsFixed(1)}';
    final tp = TextPainter(
      text: TextSpan(
        text: labelText,
        style: TextStyle(
          color: color.withValues(alpha: opacity),
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(screenX + 4, _chartClip.top + 24));
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

      // Color swatch — prefer fillColor for filled series types
      final baseColor = s.fillColor ?? s.strokeColor;
      final swatchColor = isHidden
          ? baseColor.withValues(alpha: 0.3)
          : baseColor;
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
        : (xAxis?.isDateTime == true)
            ? formatDateTime(dataX, _xMax - _xMin)
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

      final name = s.seriesName ?? s.seriesId ?? 'Series ${i + 1}';
      final yLabel = _formatTooltipValue(
          yValues[idx], xValues[idx], s.tooltipFormat,
          yAxis?.labelFormat, yIsLog, yAxis?.logarithmicBase ?? 10.0,
          seriesName: name, seriesIndex: i);
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
    final xIsDateTime = xAxis?.isDateTime == true;
    final xLogBase = xAxis?.logarithmicBase ?? 10.0;
    final ticks = xIsLog
        ? calculateLogTicks(_xMin, _xMax, xLogBase)
        : xIsDateTime
            ? calculateDateTimeTicks(_xMin, _xMax, xAxis?.majorTickCount ?? 8)
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
          : xIsDateTime
              ? formatDateTime(tick, _xMax - _xMin)
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

  // ---------------------------------------------------------------------------
  // Left Y axis (secondary, for dual-axis charts)
  // ---------------------------------------------------------------------------

  void _drawLeftYAxis(Canvas canvas, Size size) {
    if (yAxis2 == null) return;
    final ax = yAxis2!;

    final axisPaint = Paint()
      ..color = ax.axisLineColor
      ..strokeWidth = 1.0;

    // Vertical axis line on the left edge of chart clip
    canvas.drawLine(
      Offset(_chartClip.left, _chartClip.top),
      Offset(_chartClip.left, _chartClip.bottom),
      axisPaint,
    );

    final y2IsLog = ax.isLogarithmic;
    final y2LogBase = ax.logarithmicBase ?? 10.0;
    final ticks = y2IsLog
        ? calculateLogTicks(_y2Min, _y2Max, y2LogBase)
        : calculateTicks(_y2Min, _y2Max, ax.majorTickCount ?? 10);
    final tickPaint = Paint()
      ..color = ax.majorTickColor
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: ax.axisLabelColor,
      fontSize: ax.axisLabelFontSize,
    );

    for (final tick in ticks) {
      final y = _dataToScreenY2(tick);
      if (y < _chartClip.top || y > _chartClip.bottom) continue;

      // Tick mark on left side
      canvas.drawLine(
        Offset(_chartClip.left - 6, y),
        Offset(_chartClip.left, y),
        tickPaint,
      );

      final label = y2IsLog
          ? _formatLogNumber(tick, y2LogBase, labelFormat: ax.labelFormat)
          : _formatNumber(tick, labelFormat: ax.labelFormat);
      final textSpan = TextSpan(text: label, style: textStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(_chartClip.left - 8 - textPainter.width, y - textPainter.height / 2),
      );
    }

    if (ax.axisTitle != null) {
      canvas.save();
      canvas.translate(14, _chartClip.top + _chartClip.height / 2);
      canvas.rotate(-math.pi / 2);

      final titleStyle = TextStyle(
        color: ax.axisTitleColor,
        fontSize: ax.axisTitleFontSize,
      );
      final textSpan = TextSpan(text: ax.axisTitle, style: titleStyle);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(-textPainter.width / 2, 0));

      canvas.restore();
    }
  }

  /// Format a tooltip value using per-series tooltipFormat, falling back to axis labelFormat.
  ///
  /// Format a tooltip value. Tries MicroPython f-string evaluation first,
  /// falls back to Dart regex parser, then to axis label format.
  ///
  /// tooltipFormat can be:
  ///   - Legacy placeholder: "{y:.2f}", "{y:,.0f}", "{x:.1f} / {y:.2f}"
  ///   - Python f-string:   f"{y:.1f}°C ({y * 9/5 + 32:.1f}°F)"
  /// Context variables: x, y, series_name, series_index
  String _formatTooltipValue(double yValue, double xValue, String? tooltipFormat,
      String? axisLabelFormat, bool yIsLog, double logBase,
      {String? seriesName, int seriesIndex = 0}) {
    if (tooltipFormat != null && tooltipFormat.isNotEmpty) {
      // Try MicroPython f-string evaluation first
      final mpResult = _formatViaMicroPython(
          tooltipFormat, yValue, xValue, seriesName, seriesIndex);
      if (mpResult != null) return mpResult;

      // Fall back to Dart regex formatter
      final result = _applyTooltipTemplate(tooltipFormat, yValue, xValue);
      if (result != null) return result;
    }
    // Fall back to axis label format
    return yIsLog
        ? _formatLogNumber(yValue, logBase, labelFormat: axisLabelFormat)
        : _formatNumber(yValue, labelFormat: axisLabelFormat);
  }

  /// Cache for MicroPython format results to avoid redundant evals
  /// when hovering over the same data point across consecutive frames.
  static final Map<String, String> _fmtCache = {};

  /// Attempt to format a tooltip value via MicroPython f-string evaluation.
  /// Returns null if MicroPython is not available or eval fails (caller
  /// should fall back to the Dart regex formatter).
  /// Regex to rewrite {:,.Nf} specs to cfmt() calls since MicroPython
  /// doesn't support the comma thousands separator in format specs.
  /// Matches: {expr:,.Nf} and rewrites to {cfmt(expr, N)}
  static final _commaFmtPattern = RegExp(r'\{([^}]*?):\s*,\.(\d+)f\}');

  static String? _formatViaMicroPython(
      String tooltipFormat, double yValue, double xValue,
      String? seriesName, int seriesIndex) {
    if (!MicroPythonService.isReady) return null;

    // Normalize format string to a Python f-string expression.
    // Legacy "{y:.2f}" becomes f"{y:.2f}" which is valid Python.
    String fStringCode;
    if (tooltipFormat.startsWith('f"') || tooltipFormat.startsWith("f'")) {
      fStringCode = tooltipFormat;
    } else {
      fStringCode = 'f"$tooltipFormat"';
    }

    // Rewrite {:,.Nf} to {cfmt(expr, N)} for MicroPython compatibility.
    // e.g. f"{y+100:,.2f}" -> f"{cfmt(y+100, 2)}"
    fStringCode = fStringCode.replaceAllMapped(_commaFmtPattern,
        (m) => '{cfmt(${m.group(1)}, ${m.group(2)})}');

    // Check cache — same format + same data point = same result
    final cacheKey = '$fStringCode|$xValue|$yValue|$seriesIndex';
    final cached = _fmtCache[cacheKey];
    if (cached != null) return cached;

    try {
      final context = <String, dynamic>{
        'x': xValue,
        'y': yValue,
        'series_name': seriesName ?? '',
        'series_index': seriesIndex,
      };

      final result = MicroPythonService.fmt(fStringCode, context);
      if (result != null) {
        // Keep cache small — clear when it grows beyond a paint cycle's worth
        if (_fmtCache.length > 50) _fmtCache.clear();
        _fmtCache[cacheKey] = result;
        return result;
      }
    } catch (_) {
      // Silently fall through to Dart formatter
    }
    return null;
  }

  /// Apply a tooltip template string with {y...} and {x...} placeholders.
  /// Returns null if the template can't be parsed.
  static String? _applyTooltipTemplate(String template, double yValue, double xValue) {
    // Match all {y...} and {x...} placeholders
    final pattern = RegExp(r'\{([xy])(?::([^}]*))?\}');
    if (!pattern.hasMatch(template)) return null;

    return template.replaceAllMapped(pattern, (m) {
      final axis = m.group(1)!;
      final spec = m.group(2); // format spec after the colon, e.g. ",.2f"
      final value = axis == 'y' ? yValue : xValue;
      if (spec == null || spec.isEmpty) {
        return value.toStringAsFixed(1);
      }
      return _applyFormatSpec(value, spec) ?? value.toString();
    });
  }

  /// Apply a Python-style format spec like ".2f", ",.2f", ".1%", ".3e", ".4g".
  static String? _applyFormatSpec(double value, String spec) {
    // Parse optional comma flag and format spec: [,][.N][type]
    final match = RegExp(r'^(,?)\.(\d+)([fFeEgG%])$').firstMatch(spec);
    if (match == null) return null;

    final bool useCommas = match.group(1) == ',';
    final int precision = int.parse(match.group(2)!);
    final String specifier = match.group(3)!.toLowerCase();

    String result;
    switch (specifier) {
      case 'f':
        result = value.toStringAsFixed(precision);
        break;
      case 'e':
        result = value.toStringAsExponential(precision);
        break;
      case 'g':
        if (value == 0) {
          result = value.toStringAsFixed(0);
        } else {
          final exp = (math.log(value.abs()) / math.ln10).floor();
          if (exp < -4 || exp >= precision) {
            result = value.toStringAsExponential(precision - 1);
          } else {
            result = value.toStringAsPrecision(precision);
          }
        }
        break;
      case '%':
        result = '${(value * 100).toStringAsFixed(precision)}%';
        break;
      default:
        return null;
    }

    if (useCommas && specifier != '%') {
      result = _addThousandsSeparator(result);
    } else if (useCommas && specifier == '%') {
      // Apply commas to the numeric part before the %
      final numPart = result.substring(0, result.length - 1);
      result = '${_addThousandsSeparator(numPart)}%';
    }
    return result;
  }

  /// Add thousands separators (commas) to the integer part of a number string.
  static String _addThousandsSeparator(String numStr) {
    final isNegative = numStr.startsWith('-');
    if (isNegative) numStr = numStr.substring(1);

    final parts = numStr.split('.');
    final intPart = parts[0];
    final decPart = parts.length > 1 ? '.${parts[1]}' : '';

    // Insert commas every 3 digits from the right
    final buf = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }

    return '${isNegative ? '-' : ''}$buf$decPart';
  }

  /// Try to apply a Python-style format string like "{:.2f}", "{:.3e}", "{:.4g}", "{:.1%}".
  /// Also supports comma separator: "{:,.2f}".
  /// Returns null if format is unrecognized (caller should fall back to default).
  static String? _applyLabelFormat(double value, String? format) {
    if (format == null || format.isEmpty) return null;

    // Match Python format specs: {:,.Nf}, {:.Nf}, {:.Ne}, {:.Ng}, {:.N%}
    final match = RegExp(r'^\{:(,?)\.(\d+)([fFeEgG%])\}$').firstMatch(format);
    if (match == null) return null;

    final bool useCommas = match.group(1) == ',';
    final int precision = int.parse(match.group(2)!);
    final String specifier = match.group(3)!.toLowerCase();

    String result;
    switch (specifier) {
      case 'f':
        result = value.toStringAsFixed(precision);
        break;
      case 'e':
        result = value.toStringAsExponential(precision);
        break;
      case 'g':
        // 'g' uses exponential if exponent < -4 or >= precision, else fixed
        if (value == 0) {
          result = value.toStringAsFixed(0);
        } else {
          final exp = (math.log(value.abs()) / math.ln10).floor();
          if (exp < -4 || exp >= precision) {
            result = value.toStringAsExponential(precision - 1);
          } else {
            result = value.toStringAsPrecision(precision);
          }
        }
        break;
      case '%':
        result = '${(value * 100).toStringAsFixed(precision)}%';
        break;
      default:
        return null;
    }

    if (useCommas && specifier != '%') {
      result = _addThousandsSeparator(result);
    } else if (useCommas && specifier == '%') {
      final numPart = result.substring(0, result.length - 1);
      result = '${_addThousandsSeparator(numPart)}%';
    }
    return result;
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
        oldDelegate.dataBuffers.generation != dataBuffers.generation ||
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
        oldDelegate.canRedo != canRedo ||
        !identical(oldDelegate.renderState, renderState);
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
