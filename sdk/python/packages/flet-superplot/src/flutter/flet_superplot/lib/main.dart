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
  // Performance test: set to 100000 for LTTB decimation testing.
  // Set to 1000 for SciChart pixel-comparison mode.
  static const int testPoints = 100000;

  // Test configuration
  static const testConfig = {
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
    'xRange': {'min': 0.0, 'max': 10.0},
    'yRange': {'min': 0.0, 'max': 100.0},
  };

  late List<SeriesModel> _series;
  late AxisModel _xAxis;
  late AxisModel _yAxis;

  @override
  void initState() {
    super.initState();
    _generateData();
  }

  void _generateData() {
    final xMin = (testConfig['xRange'] as Map)['min'] as double;
    final xMax = (testConfig['xRange'] as Map)['max'] as double;

    // Generate series 1 - Blue sine wave
    final series1Config = testConfig['series1'] as Map;
    final data1 = _generateSineWave(
      points: series1Config['points'] as int,
      frequency: series1Config['frequency'] as double,
      amplitude: series1Config['amplitude'] as double,
      offset: series1Config['offset'] as double,
      xMin: xMin,
      xMax: xMax,
    );

    // Generate series 2 - Red sine wave
    final series2Config = testConfig['series2'] as Map;
    final data2 = _generateSineWave(
      points: series2Config['points'] as int,
      frequency: series2Config['frequency'] as double,
      amplitude: series2Config['amplitude'] as double,
      offset: series2Config['offset'] as double,
      xMin: xMin,
      xMax: xMax,
    );

    _series = [
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
      visibleRangeMin: (testConfig['yRange'] as Map)['min'] as double,
      visibleRangeMax: (testConfig['yRange'] as Map)['max'] as double,
      autoRange: 'never',
      growByMin: 0.1,
      growByMax: 0.1,
    );
  }

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

    return DataPoints(
      xValues: xValues,
      yValues: yValues,
    );
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
            showMinorGridLines: false,
            majorGridLineColor: const Color(0xFF333333),
            minorGridLineColor: const Color(0xFF222222),
          ),
        ),
      ),
    );
  }
}
