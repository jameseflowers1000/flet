import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'src/interactive_chart.dart';
import 'src/models/axis_model.dart';
import 'src/models/series_model.dart';

/// Standalone test app for SuperPlot visual comparison with SciChart.
///
/// Supports ?chart=<type> URL parameter for per-chart-type comparison.
/// Data generation matches scichart_reference.html exactly for pixel-level comparison.
///
/// Supported types: mixed (default), line, scatter, mountain, column, candlestick, band
void main() {
  runApp(const SuperPlotTestApp());
}

class SuperPlotTestApp extends StatelessWidget {
  const SuperPlotTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SuperPlot Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const SuperPlotTestPage(),
    );
  }
}

class SuperPlotTestPage extends StatefulWidget {
  const SuperPlotTestPage({super.key});

  @override
  State<SuperPlotTestPage> createState() => _SuperPlotTestPageState();
}

class _SuperPlotTestPageState extends State<SuperPlotTestPage> {
  late List<SeriesModel> _series;
  late AxisModel _xAxis;
  late AxisModel _yAxis;
  AxisModel? _yAxis2; // Secondary Y axis (for dual_axis chart)
  final DataBufferStore _dataBuffers = DataBufferStore();

  String _chartType = 'mixed';

  @override
  void initState() {
    super.initState();
    // Parse URL parameter for web; default to 'mixed'
    _chartType = _getChartTypeFromUrl();
    _buildChart();
  }

  String _getChartTypeFromUrl() {
    try {
      final uri = Uri.base;
      return uri.queryParameters['chart'] ?? 'mixed';
    } catch (_) {
      return 'mixed';
    }
  }

  void _buildChart() {
    _yAxis2 = null; // Reset secondary axis (only dual_axis sets it)
    switch (_chartType) {
      case 'line':
        _buildLineChart();
      case 'scatter':
        _buildScatterChart();
      case 'mountain':
        _buildMountainChart();
      case 'column':
        _buildColumnChart();
      case 'candlestick':
        _buildCandlestickChart();
      case 'band':
        _buildBandChart();
      case 'dual_axis':
        _buildDualAxisChart();
      case 'datetime':
        _buildDateTimeChart();
      case 'impulse':
        _buildImpulseChart();
      case 'bubble':
        _buildBubbleChart();
      case 'error_bar':
        _buildErrorBarChart();
      case 'box_plot':
        _buildBoxPlotChart();
      case 'waterfall':
        _buildWaterfallChart();
      case 'stacked_column':
        _buildStackedColumnChart();
      case 'stacked_mountain':
        _buildStackedMountainChart();
      default:
        _buildMixedChart();
    }
  }

  // ── Mixed (original log Y test) ────────────────────────────────────

  void _buildMixedChart() {
    const double xMin = 0.0, xMax = 10.0;

    final data1 = _generateExponential(1000, 10.0, 0.3, 1.0, xMin, xMax);
    final data2 = _generateExponential(1000, 10.0, 0.2, 5.0, xMin, xMax);
    final mountainData = _generateExponential(1000, 10.0, 0.15, 1.0, xMin, xMax);
    final scatterData = _samplePoints(data1, 20);

    _series = [
      SeriesModel(type: 'mountain', data: mountainData,
        strokeColor: const Color(0xFF50C878), strokeThickness: 2.0,
        fillColor: const Color(0x5550C878), zeroLineY: 0.5),
      SeriesModel(type: 'fast_line', data: data1,
        strokeColor: const Color(0xFF4083FF), strokeThickness: 2.0),
      SeriesModel(type: 'fast_line', data: data2,
        strokeColor: const Color(0xFFFF6347), strokeThickness: 2.0,
        pointMarkerType: 'circle', pointMarkerSize: 6.0,
        pointMarkerColor: const Color(0xFFFF6347)),
      SeriesModel(type: 'scatter', data: scatterData,
        pointMarkerType: 'circle', pointMarkerSize: 10.0,
        pointMarkerColor: const Color(0xFFFF6600),
        strokeColor: const Color(0xFFFF6600), strokeThickness: 1.0),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Time (s)',
      visibleRangeMin: xMin, visibleRangeMax: xMax, autoRange: 'never',
      growByMin: 0.1, growByMax: 0.1);
    _yAxis = AxisModel(type: 'logarithmic', axisTitle: 'Value',
      visibleRangeMin: 1.0, visibleRangeMax: 10000.0, autoRange: 'never',
      growByMin: 0.1, growByMax: 0.1, logarithmicBase: 10.0);
  }

  // ── Line ────────────────────────────────────────────────────────────

  void _buildLineChart() {
    final d1 = _generateSineWave(500, 2.0, 40.0, 50.0, 0, 10);
    final d2 = _generateSineWave(500, 3.5, 25.0, 55.0, 0, 10);

    _series = [
      SeriesModel(type: 'fast_line', data: d1,
        strokeColor: const Color(0xFF4083FF), strokeThickness: 2.0),
      SeriesModel(type: 'fast_line', data: d2,
        strokeColor: const Color(0xFFFF6347), strokeThickness: 2.0,
        pointMarkerType: 'circle', pointMarkerSize: 5.0,
        pointMarkerColor: const Color(0xFFFF6347)),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'X',
      visibleRangeMin: 0, visibleRangeMax: 10, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Y',
      visibleRangeMin: -10, visibleRangeMax: 110, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Scatter ─────────────────────────────────────────────────────────

  void _buildScatterChart() {
    const int n = 200;

    // Lissajous curves — matches JS exactly
    final x1 = Float64List(n), y1 = Float64List(n);
    final x2 = Float64List(n), y2 = Float64List(n);
    for (int i = 0; i < n; i++) {
      final t = (i / n) * 2 * math.pi;
      x1[i] = math.sin(3 * t);
      y1[i] = math.cos(2 * t);
      x2[i] = math.sin(2 * t + 0.5);
      y2[i] = math.cos(3 * t + 0.5);
    }

    _series = [
      SeriesModel(type: 'scatter',
        data: DataPoints(xValues: x1, yValues: y1),
        pointMarkerType: 'circle', pointMarkerSize: 8.0,
        pointMarkerColor: const Color(0xFF4083FF),
        strokeColor: const Color(0xFF4083FF), strokeThickness: 1.0),
      SeriesModel(type: 'scatter',
        data: DataPoints(xValues: x2, yValues: y2),
        pointMarkerType: 'triangle', pointMarkerSize: 8.0,
        pointMarkerColor: const Color(0xFFFF6347),
        strokeColor: const Color(0xFFFF6347), strokeThickness: 1.0),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'X',
      visibleRangeMin: -1.5, visibleRangeMax: 1.5, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Y',
      visibleRangeMin: -1.5, visibleRangeMax: 1.5, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Mountain ────────────────────────────────────────────────────────

  void _buildMountainChart() {
    final d1 = _generateSineWave(500, 1.5, 30.0, 50.0, 0, 10);
    final d2 = _generateSineWave(500, 2.5, 20.0, 35.0, 0, 10);

    _series = [
      SeriesModel(type: 'mountain', data: d1,
        strokeColor: const Color(0xFF4083FF), strokeThickness: 2.0,
        fillColor: const Color(0x554083FF), zeroLineY: 0.0),
      SeriesModel(type: 'mountain', data: d2,
        strokeColor: const Color(0xFF50C878), strokeThickness: 2.0,
        fillColor: const Color(0x5550C878), zeroLineY: 0.0),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'X',
      visibleRangeMin: 0, visibleRangeMax: 10, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Y',
      visibleRangeMin: 0, visibleRangeMax: 100, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Column ──────────────────────────────────────────────────────────

  void _buildColumnChart() {
    // 10 bars: deterministic values from sin — matches JS exactly
    final xValues = Float64List(10), yValues = Float64List(10);
    for (int i = 0; i < 10; i++) {
      xValues[i] = i.toDouble();
      yValues[i] = 50 * math.sin(i * 0.8) + 10 * math.cos(i * 1.3);
    }

    _series = [
      SeriesModel(type: 'column',
        data: DataPoints(xValues: xValues, yValues: yValues),
        fillColor: const Color(0xFF4083FF),
        strokeColor: const Color(0xFF2060CC), strokeThickness: 1.0,
        barWidth: 0.7),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Category',
      visibleRangeMin: -0.5, visibleRangeMax: 9.5, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: -50, visibleRangeMax: 80, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Candlestick ─────────────────────────────────────────────────────

  void _buildCandlestickChart() {
    const int count = 50;
    const int seed = 42;

    // Deterministic pseudo-random (mulberry32) matching JS exactly
    int s = seed;
    double nextRand() {
      s |= 0;
      s = s + 0x6D2B79F5;
      int t = (s ^ (s >>> 15)) * (1 | s);
      t = (t + (t ^ (t >>> 7)) * (61 | t)) ^ t;
      return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296.0;
    }

    final xValues = Float64List(count);
    final openValues = Float64List(count);
    final highValues = Float64List(count);
    final lowValues = Float64List(count);
    final closeValues = Float64List(count);

    double price = 100;
    double yMin = double.infinity, yMax = double.negativeInfinity;
    for (int i = 0; i < count; i++) {
      final open = price;
      final change1 = (nextRand() - 0.48) * 4;
      final change2 = (nextRand() - 0.48) * 4;
      final mid = open + change1;
      final close = mid + change2;
      final high = math.max(open, close) + nextRand() * 3;
      final low = math.min(open, close) - nextRand() * 3;

      xValues[i] = i.toDouble();
      openValues[i] = open;
      highValues[i] = high;
      lowValues[i] = low;
      closeValues[i] = close;
      price = close;

      if (high > yMax) yMax = high;
      if (low < yMin) yMin = low;
    }

    // Populate DataBufferStore with named columns for the candlestick painter
    _dataBuffers['x'] = xValues;
    _dataBuffers['open'] = openValues;
    _dataBuffers['high'] = highValues;
    _dataBuffers['low'] = lowValues;
    _dataBuffers['close'] = closeValues;

    _series = [
      SeriesModel(type: 'candlestick',
        xCol: 'x', openCol: 'open', highCol: 'high',
        lowCol: 'low', closeCol: 'close',
        upColor: const Color(0xFF26A69A),
        downColor: const Color(0xFFEF5350),
        bodyWidth: 0.6),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Day',
      visibleRangeMin: -1, visibleRangeMax: 51, autoRange: 'never',
      growByMin: 0.02, growByMax: 0.02);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Price',
      visibleRangeMin: yMin - 5, visibleRangeMax: yMax + 5, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Band ────────────────────────────────────────────────────────────

  void _buildBandChart() {
    const int n = 500;
    final xValues = Float64List(n);
    final yHighValues = Float64List(n);
    final yLowValues = Float64List(n);

    for (int i = 0; i < n; i++) {
      final x = (i / (n - 1)) * 10;
      final center = 50 + 30 * math.sin(2 * math.pi * 1.5 * x / 10);
      final envelope = 10 + 8 * math.sin(2 * math.pi * 0.5 * x / 10);
      xValues[i] = x;
      yHighValues[i] = center + envelope;
      yLowValues[i] = center - envelope;
    }

    // Populate DataBufferStore with named columns for the band painter
    _dataBuffers['x'] = xValues;
    _dataBuffers['y_high'] = yHighValues;
    _dataBuffers['y_low'] = yLowValues;

    _series = [
      SeriesModel(type: 'band',
        xCol: 'x', yHighCol: 'y_high', yLowCol: 'y_low',
        fillColor: const Color(0x332196F3),
        strokeColor: const Color(0xFF2196F3),
        strokeThickness: 1.0),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'X',
      visibleRangeMin: 0, visibleRangeMax: 10, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Y',
      visibleRangeMin: -20, visibleRangeMax: 120, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Dual Axis ──────────────────────────────────────────────────────

  void _buildDualAxisChart() {
    // Line series on primary Y axis (right) — temperature
    final d1 = _generateSineWave(500, 2.0, 40.0, 50.0, 0, 10);

    // Column series on secondary Y axis (left) — volume
    final xCols = Float64List(10), yCols = Float64List(10);
    for (int i = 0; i < 10; i++) {
      xCols[i] = i + 0.5;
      yCols[i] = 30 + 20 * math.sin(i * 0.9);
    }

    _series = [
      SeriesModel(type: 'fast_line', data: d1,
        strokeColor: const Color(0xFF4083FF), strokeThickness: 2.0,
        yAxisId: 'y0'),
      SeriesModel(type: 'column',
        data: DataPoints(xValues: xCols, yValues: yCols),
        fillColor: const Color(0x8026A69A),
        strokeColor: const Color(0xFF26A69A), strokeThickness: 1.0,
        barWidth: 0.7,
        yAxisId: 'y1'),
    ];

    _xAxis = AxisModel(id: 'x0', type: 'numeric', axisTitle: 'X',
      visibleRangeMin: 0, visibleRangeMax: 10, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(id: 'y0', type: 'numeric', axisTitle: 'Temperature',
      visibleRangeMin: -10, visibleRangeMax: 110, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis2 = AxisModel(id: 'y1', type: 'numeric', axisTitle: 'Volume',
      axisAlignment: 'left',
      visibleRangeMin: 0, visibleRangeMax: 100, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── DateTime ────────────────────────────────────────────────────────

  void _buildDateTimeChart() {
    // 365 days starting from 2024-01-01 — matches SciChart reference exactly
    const int n = 365;
    final startMs = DateTime.utc(2024, 1, 1).millisecondsSinceEpoch.toDouble();
    final xValues = Float64List(n);
    final yValues = Float64List(n);

    for (int i = 0; i < n; i++) {
      xValues[i] = startMs + i * 86400000.0; // epoch-milliseconds
      yValues[i] = 50 + 30 * math.sin(2 * math.pi * i / 90)
                      + 10 * math.cos(2 * math.pi * i / 30);
    }

    _series = [
      SeriesModel(type: 'fast_line',
        data: DataPoints(xValues: xValues, yValues: yValues),
        strokeColor: const Color(0xFF4083FF), strokeThickness: 2.0),
    ];

    _xAxis = AxisModel(type: 'datetime', axisTitle: 'Date',
      visibleRangeMin: xValues.first, visibleRangeMax: xValues.last,
      autoRange: 'never', growByMin: 0.02, growByMax: 0.02);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: 0, visibleRangeMax: 100, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Bubble ─────────────────────────────────────────────────────────

  void _buildBubbleChart() {
    const int n = 30;
    final xValues = Float64List(n);
    final yValues = Float64List(n);
    final sizeValues = Float64List(n);

    for (int i = 0; i < n; i++) {
      xValues[i] = math.sin(i * 0.5) * 50 + 50;
      yValues[i] = math.cos(i * 0.3) * 40 + 50;
      sizeValues[i] = 5 + 25 * ((math.sin(i * 0.7) + 1) / 2);
    }

    _dataBuffers['x'] = xValues;
    _dataBuffers['y'] = yValues;
    _dataBuffers['size'] = sizeValues;

    _series = [
      SeriesModel(type: 'bubble',
        xCol: 'x', yCol: 'y', sizeCol: 'size',
        strokeColor: const Color(0xFF4083FF), opacity: 0.7),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'X',
      visibleRangeMin: -10, visibleRangeMax: 110, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Y',
      visibleRangeMin: -10, visibleRangeMax: 110, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Error Bar ─────────────────────────────────────────────────────

  void _buildErrorBarChart() {
    const int n = 15;
    final xValues = Float64List(n);
    final yValues = Float64List(n);
    final errHigh = Float64List(n);
    final errLow = Float64List(n);

    for (int i = 0; i < n; i++) {
      xValues[i] = i.toDouble();
      yValues[i] = 50 + 30 * math.sin(i * 0.5);
      errHigh[i] = 3 + 5 * ((math.sin(i * 0.8) + 1) / 2);
      errLow[i] = 3 + 5 * ((math.cos(i * 0.8) + 1) / 2);
    }

    _dataBuffers['x'] = xValues;
    _dataBuffers['y'] = yValues;
    _dataBuffers['err_high'] = errHigh;
    _dataBuffers['err_low'] = errLow;

    _series = [
      SeriesModel(type: 'error_bar',
        xCol: 'x', yCol: 'y',
        errorHighCol: 'err_high', errorLowCol: 'err_low',
        strokeColor: const Color(0xFF4083FF), strokeThickness: 1.5,
        capWidth: 8.0),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Index',
      visibleRangeMin: -1, visibleRangeMax: 15, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: 0, visibleRangeMax: 100, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Box Plot ──────────────────────────────────────────────────────

  void _buildBoxPlotChart() {
    const int n = 8;
    final xValues = Float64List(n);
    final minValues = Float64List(n);
    final q1Values = Float64List(n);
    final medianValues = Float64List(n);
    final q3Values = Float64List(n);
    final maxValues = Float64List(n);

    for (int i = 0; i < n; i++) {
      xValues[i] = i.toDouble();
      final base = 30 + 15 * math.sin(i * 0.8);
      minValues[i] = base - 10 - 5 * ((math.sin(i * 1.3) + 1) / 2);
      q1Values[i] = base - 3;
      medianValues[i] = base + 2 * math.cos(i * 0.5);
      q3Values[i] = base + 8;
      maxValues[i] = base + 15 + 5 * ((math.cos(i * 0.9) + 1) / 2);
    }

    _dataBuffers['x'] = xValues;
    _dataBuffers['min'] = minValues;
    _dataBuffers['q1'] = q1Values;
    _dataBuffers['median'] = medianValues;
    _dataBuffers['q3'] = q3Values;
    _dataBuffers['max'] = maxValues;

    _series = [
      SeriesModel(type: 'box_plot',
        xCol: 'x', minCol: 'min', q1Col: 'q1',
        medianCol: 'median', q3Col: 'q3', maxCol: 'max',
        fillColor: const Color(0x404083FF),
        strokeColor: const Color(0xFF4083FF),
        medianColor: Colors.white,
        strokeThickness: 1.5),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Group',
      visibleRangeMin: -1, visibleRangeMax: 8, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: 0, visibleRangeMax: 70, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Waterfall ─────────────────────────────────────────────────────

  void _buildWaterfallChart() {
    const int n = 10;
    final xValues = Float64List(n);
    final yValues = Float64List(n);

    // Positive/negative contributions
    final vals = [20.0, 15.0, -8.0, 12.0, -5.0, 25.0, -10.0, 8.0, -3.0, 18.0];
    for (int i = 0; i < n; i++) {
      xValues[i] = i.toDouble();
      yValues[i] = vals[i];
    }

    _series = [
      SeriesModel(type: 'waterfall',
        data: DataPoints(xValues: xValues, yValues: yValues),
        upColor: const Color(0xFF26A69A),
        downColor: const Color(0xFFEF5350),
        strokeColor: const Color(0xFF888888)),
    ];

    // Calculate cumulative range
    double cum = 0, maxCum = 0, minCum = 0;
    for (final v in vals) {
      cum += v;
      if (cum > maxCum) maxCum = cum;
      if (cum < minCum) minCum = cum;
    }

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Category',
      visibleRangeMin: -0.5, visibleRangeMax: 9.5, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: minCum - 10, visibleRangeMax: maxCum + 10,
      autoRange: 'never', growByMin: 0.05, growByMax: 0.05);
  }

  // ── Stacked Column ────────────────────────────────────────────────

  void _buildStackedColumnChart() {
    // 3 stacked series over 8 categories
    const int n = 8;
    final xValues = Float64List(n);
    final y1 = Float64List(n), y2 = Float64List(n), y3 = Float64List(n);

    for (int i = 0; i < n; i++) {
      xValues[i] = i.toDouble();
      y1[i] = 10 + 15 * ((math.sin(i * 0.7) + 1) / 2);
      y2[i] = 8 + 12 * ((math.cos(i * 0.5) + 1) / 2);
      y3[i] = 5 + 10 * ((math.sin(i * 1.1) + 1) / 2);
    }

    _series = [
      SeriesModel(type: 'column',
        data: DataPoints(xValues: xValues, yValues: y1),
        fillColor: const Color(0xFF4083FF),
        strokeColor: const Color(0xFF2060CC), barWidth: 0.7,
        stackGroup: 'g1'),
      SeriesModel(type: 'column',
        data: DataPoints(xValues: xValues, yValues: y2),
        fillColor: const Color(0xFF26A69A),
        strokeColor: const Color(0xFF1B7A70), barWidth: 0.7,
        stackGroup: 'g1'),
      SeriesModel(type: 'column',
        data: DataPoints(xValues: xValues, yValues: y3),
        fillColor: const Color(0xFFFF6347),
        strokeColor: const Color(0xFFCC4F38), barWidth: 0.7,
        stackGroup: 'g1'),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Category',
      visibleRangeMin: -0.5, visibleRangeMax: 7.5, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: 0, visibleRangeMax: 60, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Stacked Mountain ──────────────────────────────────────────────

  void _buildStackedMountainChart() {
    const int n = 200;
    final d1 = _generateSineWave(n, 1.5, 15.0, 20.0, 0, 10);
    final d2 = _generateSineWave(n, 2.0, 10.0, 15.0, 0, 10);
    final d3 = _generateSineWave(n, 2.5, 8.0, 12.0, 0, 10);

    _series = [
      SeriesModel(type: 'mountain', data: d1,
        strokeColor: const Color(0xFF4083FF), strokeThickness: 1.5,
        fillColor: const Color(0x884083FF), zeroLineY: 0.0,
        stackGroup: 'g1'),
      SeriesModel(type: 'mountain', data: d2,
        strokeColor: const Color(0xFF26A69A), strokeThickness: 1.5,
        fillColor: const Color(0x8826A69A), zeroLineY: 0.0,
        stackGroup: 'g1'),
      SeriesModel(type: 'mountain', data: d3,
        strokeColor: const Color(0xFFFF6347), strokeThickness: 1.5,
        fillColor: const Color(0x88FF6347), zeroLineY: 0.0,
        stackGroup: 'g1'),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'X',
      visibleRangeMin: 0, visibleRangeMax: 10, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Y',
      visibleRangeMin: 0, visibleRangeMax: 80, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Impulse/Stem ──────────────────────────────────────────────────

  void _buildImpulseChart() {
    const int n = 30;
    final xValues = Float64List(n);
    final yValues = Float64List(n);

    for (int i = 0; i < n; i++) {
      xValues[i] = i.toDouble();
      yValues[i] = 50 * math.sin(i * 0.5) + 10 * math.cos(i * 1.2);
    }

    _series = [
      SeriesModel(type: 'impulse',
        data: DataPoints(xValues: xValues, yValues: yValues),
        strokeColor: const Color(0xFF4083FF), strokeThickness: 2.0),
    ];

    _xAxis = AxisModel(type: 'numeric', axisTitle: 'Index',
      visibleRangeMin: -1, visibleRangeMax: 30, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
    _yAxis = AxisModel(type: 'numeric', axisTitle: 'Value',
      visibleRangeMin: -60, visibleRangeMax: 70, autoRange: 'never',
      growByMin: 0.05, growByMax: 0.05);
  }

  // ── Shared data generators ──────────────────────────────────────────

  DataPoints _generateSineWave(int points, double frequency, double amplitude,
      double offset, double xMin, double xMax) {
    final xValues = Float64List(points);
    final yValues = Float64List(points);
    final step = (xMax - xMin) / (points - 1);
    for (int i = 0; i < points; i++) {
      final x = xMin + i * step;
      final y = offset + amplitude * math.sin(
        2 * math.pi * frequency * x / (xMax - xMin));
      xValues[i] = x;
      yValues[i] = y;
    }
    return DataPoints(xValues: xValues, yValues: yValues);
  }

  DataPoints _generateExponential(int points, double base, double rate,
      double scale, double xMin, double xMax) {
    final xValues = Float64List(points);
    final yValues = Float64List(points);
    final step = (xMax - xMin) / (points - 1);
    for (int i = 0; i < points; i++) {
      final x = xMin + i * step;
      final y = scale * math.pow(base, rate * x);
      xValues[i] = x;
      yValues[i] = y;
    }
    return DataPoints(xValues: xValues, yValues: yValues);
  }

  DataPoints _samplePoints(DataPoints source, int count) {
    final step = source.length ~/ count;
    final xValues = Float64List(count);
    final yValues = Float64List(count);
    for (int i = 0; i < count; i++) {
      final idx = i * step;
      xValues[i] = source.xValues[idx];
      yValues[i] = source.yValues[idx];
    }
    return DataPoints(xValues: xValues, yValues: yValues);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1c1c1e),
      body: Center(
        child: SizedBox(
          width: 800,
          height: 600,
          child: InteractiveChart(
            xAxis: _xAxis,
            yAxis: _yAxis,
            yAxis2: _yAxis2,
            series: _series,
            dataBuffers: _dataBuffers,
            annotations: const [],
            renderState: const {},
            backgroundColor: const Color(0xFF1c1c1e),
            showMajorGridLines: true,
            showMinorGridLines: true,
            majorGridLineColor: const Color(0xFF333333),
            minorGridLineColor: const Color(0xFF222222),
          ),
        ),
      ),
    );
  }
}
