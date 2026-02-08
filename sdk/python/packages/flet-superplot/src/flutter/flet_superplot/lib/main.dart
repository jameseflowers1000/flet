import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'src/interactive_chart.dart';
import 'src/models/axis_model.dart';
import 'src/models/series_model.dart';

/// Standalone test app for SuperPlot visual comparison with SciChart.
///
/// This generates the same test data as scichart_reference.html
/// for pixel-level comparison via Playwright.
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
  // Toggle between linear (sine wave) and logarithmic (exponential) test data.
  // Set to true for log axis comparison with SciChart.
  static const bool useLogScale = true;

  // Set to 1000 for SciChart pixel-comparison mode.
  // Set to 100000 for LTTB decimation / performance testing.
  static const int testPoints = 1000;

  // Number of scatter points (evenly sampled from series1)
  static const int scatterPoints = 20;

  late List<SeriesModel> _series;
  late AxisModel _xAxis;
  late AxisModel _yAxis;

  @override
  void initState() {
    super.initState();
    if (useLogScale) {
      _generateLogData();
    } else {
      _generateLinearData();
    }
  }

  // ---------------------------------------------------------------------------
  // Logarithmic test data (exponential curves on log Y axis)
  // ---------------------------------------------------------------------------

  void _generateLogData() {
    const double xMin = 0.0;
    const double xMax = 10.0;

    // Series 1: blue exponential y = 10^(0.3*x) — spans ~1 to ~1000
    final data1 = _generateExponential(
      points: testPoints,
      base: 10.0,
      rate: 0.3,
      xMin: xMin,
      xMax: xMax,
    );

    // Series 2: red exponential y = 5 * 10^(0.2*x) — different growth
    final data2 = _generateExponential(
      points: testPoints,
      base: 10.0,
      rate: 0.2,
      scale: 5.0,
      xMin: xMin,
      xMax: xMax,
    );

    // Scatter: sampled from series1
    final scatterData = _samplePoints(data1, scatterPoints);

    // Mountain: y = 10^(0.15*x) — slowest growth, behind others
    final mountainData = _generateExponential(
      points: testPoints,
      base: 10.0,
      rate: 0.15,
      xMin: xMin,
      xMax: xMax,
    );

    _series = [
      SeriesModel(
        type: 'mountain',
        data: mountainData,
        strokeColor: const Color(0xFF50C878),
        strokeThickness: 2.0,
        fillColor: const Color(0x5550C878),
        zeroLineY: 0.5, // baseline below data on log scale
      ),
      SeriesModel(
        type: 'fast_line',
        data: data1,
        strokeColor: const Color(0xFF4083FF),
        strokeThickness: 2.0,
      ),
      SeriesModel(
        type: 'fast_line',
        data: data2,
        strokeColor: const Color(0xFFFF6347),
        strokeThickness: 2.0,
        pointMarkerType: 'circle',
        pointMarkerSize: 6.0,
        pointMarkerColor: const Color(0xFFFF6347),
      ),
      SeriesModel(
        type: 'scatter',
        data: scatterData,
        pointMarkerType: 'circle',
        pointMarkerSize: 10.0,
        pointMarkerColor: const Color(0xFFFF6600),
        strokeColor: const Color(0xFFFF6600),
        strokeThickness: 1.0,
      ),
    ];

    _xAxis = AxisModel(
      type: 'numeric',
      axisTitle: 'Time (s)',
      visibleRangeMin: xMin,
      visibleRangeMax: xMax,
      autoRange: 'never',
      growByMin: 0.1,
      growByMax: 0.1,
    );

    _yAxis = AxisModel(
      type: 'logarithmic',
      axisTitle: 'Value',
      visibleRangeMin: 1.0,
      visibleRangeMax: 10000.0,
      autoRange: 'never',
      growByMin: 0.1,
      growByMax: 0.1,
      logarithmicBase: 10.0,
    );
  }

  DataPoints _generateExponential({
    required int points,
    required double base,
    required double rate,
    double scale = 1.0,
    required double xMin,
    required double xMax,
  }) {
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

  // ---------------------------------------------------------------------------
  // Linear test data (sine waves on numeric axes)
  // ---------------------------------------------------------------------------

  // Test configuration for linear mode
  static const linearConfig = {
    'series1': {
      'points': testPoints,
      'color': '#4083ff',
      'frequency': 2.0,
      'amplitude': 50.0,
      'offset': 50.0,
    },
    'series2': {
      'points': testPoints,
      'color': '#ff6347',
      'frequency': 5.0,
      'amplitude': 30.0,
      'offset': 50.0,
    },
    'scatter': {
      'points': scatterPoints,
      'color': '#ff6600',
      'size': 10.0,
    },
    'mountain': {
      'points': testPoints,
      'color': '#50C878',
      'gradientStart': '#AA50C878',
      'gradientEnd': '#0050C878',
      'frequency': 1.5,
      'amplitude': 25.0,
      'offset': 30.0,
    },
    'xRange': {'min': 0.0, 'max': 10.0},
    'yRange': {'min': 0.0, 'max': 100.0},
  };

  void _generateLinearData() {
    final xMin = (linearConfig['xRange'] as Map)['min'] as double;
    final xMax = (linearConfig['xRange'] as Map)['max'] as double;

    final series1Config = linearConfig['series1'] as Map;
    final data1 = _generateSineWave(
      points: series1Config['points'] as int,
      frequency: series1Config['frequency'] as double,
      amplitude: series1Config['amplitude'] as double,
      offset: series1Config['offset'] as double,
      xMin: xMin,
      xMax: xMax,
    );

    final series2Config = linearConfig['series2'] as Map;
    final data2 = _generateSineWave(
      points: series2Config['points'] as int,
      frequency: series2Config['frequency'] as double,
      amplitude: series2Config['amplitude'] as double,
      offset: series2Config['offset'] as double,
      xMin: xMin,
      xMax: xMax,
    );

    final scatterConfig = linearConfig['scatter'] as Map;
    final scatterData = _samplePoints(
      data1,
      scatterConfig['points'] as int,
    );

    final mountainConfig = linearConfig['mountain'] as Map;
    final mountainData = _generateSineWave(
      points: mountainConfig['points'] as int,
      frequency: mountainConfig['frequency'] as double,
      amplitude: mountainConfig['amplitude'] as double,
      offset: mountainConfig['offset'] as double,
      xMin: xMin,
      xMax: xMax,
    );

    _series = [
      SeriesModel(
        type: 'mountain',
        data: mountainData,
        strokeColor: _parseColor(mountainConfig['color'] as String),
        strokeThickness: 2.0,
        fillColor: const Color(0x5550C878),
        zeroLineY: 0.0,
      ),
      SeriesModel(
        type: 'fast_line',
        data: data1,
        strokeColor: _parseColor(series1Config['color'] as String),
        strokeThickness: 2.0,
      ),
      SeriesModel(
        type: 'fast_line',
        data: data2,
        strokeColor: _parseColor(series2Config['color'] as String),
        strokeThickness: 2.0,
        pointMarkerType: 'circle',
        pointMarkerSize: 6.0,
        pointMarkerColor: _parseColor(series2Config['color'] as String),
      ),
      SeriesModel(
        type: 'scatter',
        data: scatterData,
        pointMarkerType: 'circle',
        pointMarkerSize: (scatterConfig['size'] as double),
        pointMarkerColor: _parseColor(scatterConfig['color'] as String),
        strokeColor: _parseColor(scatterConfig['color'] as String),
        strokeThickness: 1.0,
      ),
    ];

    _xAxis = AxisModel(
      type: 'numeric',
      axisTitle: 'Time (s)',
      visibleRangeMin: xMin,
      visibleRangeMax: xMax,
      autoRange: 'never',
      growByMin: 0.1,
      growByMax: 0.1,
    );

    _yAxis = AxisModel(
      type: 'numeric',
      axisTitle: 'Amplitude',
      visibleRangeMin: (linearConfig['yRange'] as Map)['min'] as double,
      visibleRangeMax: (linearConfig['yRange'] as Map)['max'] as double,
      autoRange: 'never',
      growByMin: 0.1,
      growByMax: 0.1,
    );
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  DataPoints _generateSineWave({
    required int points,
    required double frequency,
    required double amplitude,
    required double offset,
    required double xMin,
    required double xMax,
  }) {
    final xValues = Float64List(points);
    final yValues = Float64List(points);
    final step = (xMax - xMin) / (points - 1);

    for (int i = 0; i < points; i++) {
      final x = xMin + i * step;
      final y = offset + amplitude * math.sin(
        2 * math.pi * frequency * x / (xMax - xMin)
      );
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

  Color _parseColor(String colorStr) {
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    }
    return Colors.grey;
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
            series: _series,
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
