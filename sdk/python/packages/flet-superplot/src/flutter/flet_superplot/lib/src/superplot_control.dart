import 'dart:convert';
import 'dart:typed_data';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

import 'models/axis_model.dart';
import 'models/series_model.dart';
import 'painters/chart_painter.dart';

/// Main SuperPlot control widget.
/// 
/// Parses configuration from Flet control properties and renders
/// using CustomPainter for GPU-accelerated drawing.
class SuperPlotControl extends StatefulWidget {
  final Control control;

  const SuperPlotControl({
    super.key,
    required this.control,
  });

  @override
  State<SuperPlotControl> createState() => _SuperPlotControlState();
}

class _SuperPlotControlState extends State<SuperPlotControl> {
  AxisModel? _xAxis;
  AxisModel? _yAxis;
  List<SeriesModel> _series = [];
  
  // Chart styling from control
  Color _backgroundColor = const Color(0xFF1c1c1e);
  bool _showMajorGridLines = true;
  bool _showMinorGridLines = false;
  Color _majorGridLineColor = const Color(0xFF555555);  // Lighter for visibility
  Color _minorGridLineColor = const Color(0xFF333333);

  @override
  void initState() {
    super.initState();
    _parseConfig();
  }

  @override
  void didUpdateWidget(covariant SuperPlotControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseConfig();
  }

  void _parseConfig() {
    // Debug: use print() since debugPrint is disabled in Release builds
    print('[SuperPlot Flutter] Parsing config for control: ${widget.control.id}');
    print('[SuperPlot Flutter] Control type: ${widget.control.type}');
    
    // Parse X axis
    final xAxisJson = widget.control.getString("x_axis");
    print('[SuperPlot Flutter] x_axis: ${xAxisJson == null ? "NULL" : "${xAxisJson.length} chars"}');
    if (xAxisJson != null && xAxisJson.isNotEmpty) {
      try {
        _xAxis = AxisModel.fromJson(jsonDecode(xAxisJson));
        print('[SuperPlot Flutter] Parsed X axis: range ${_xAxis?.visibleRangeMin} to ${_xAxis?.visibleRangeMax}');
      } catch (e) {
        print('[SuperPlot Flutter] ERROR parsing x_axis: $e');
      }
    } else {
      print('[SuperPlot Flutter] x_axis is null or empty!');
    }

    // Parse Y axis
    final yAxisJson = widget.control.getString("y_axis");
    print('[SuperPlot Flutter] y_axis: ${yAxisJson == null ? "NULL" : "${yAxisJson.length} chars"}');
    if (yAxisJson != null && yAxisJson.isNotEmpty) {
      try {
        _yAxis = AxisModel.fromJson(jsonDecode(yAxisJson));
        print('[SuperPlot Flutter] Parsed Y axis: range ${_yAxis?.visibleRangeMin} to ${_yAxis?.visibleRangeMax}');
      } catch (e) {
        print('[SuperPlot Flutter] ERROR parsing y_axis: $e');
      }
    } else {
      print('[SuperPlot Flutter] y_axis is null or empty!');
    }

    // Parse series
    final seriesJson = widget.control.getString("series");
    print('[SuperPlot Flutter] series: ${seriesJson == null ? "NULL" : "${seriesJson.length} chars"}');
    if (seriesJson != null && seriesJson.isNotEmpty) {
      try {
        final seriesList = jsonDecode(seriesJson) as List;
        _series = seriesList.map((s) => SeriesModel.fromJson(s)).toList();
        print('[SuperPlot Flutter] Parsed ${_series.length} series');
        for (int i = 0; i < _series.length; i++) {
          final s = _series[i];
          print('[SuperPlot Flutter] Series $i: ${s.data?.length ?? 0} points');
        }
      } catch (e) {
        print('[SuperPlot Flutter] ERROR parsing series: $e');
      }
    } else {
      print('[SuperPlot Flutter] series is null or empty!');
    }

    // Parse styling
    final bgColor = widget.control.getString("background_color");
    if (bgColor != null) {
      _backgroundColor = _parseColor(bgColor);
    }

    _showMajorGridLines = widget.control.getBool("show_major_grid_lines", true)!;
    _showMinorGridLines = widget.control.getBool("show_minor_grid_lines", false)!;

    final majorGridColor = widget.control.getString("major_grid_line_color");
    if (majorGridColor != null) {
      _majorGridLineColor = _parseColor(majorGridColor);
    }

    final minorGridColor = widget.control.getString("minor_grid_line_color");
    if (minorGridColor != null) {
      _minorGridLineColor = _parseColor(minorGridColor);
    }
  }

  Color _parseColor(String colorStr) {
    // Handle hex colors like "#1c1c1e" or "#ff1c1c1e"
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex'; // Add alpha
      }
      return Color(int.parse(hex, radix: 16));
    }
    // Could add named color support here
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    print('[SuperPlot Flutter] build() called, xAxis: $_xAxis, yAxis: $_yAxis, series: ${_series.length}');
    
    return ConstrainedControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          print('[SuperPlot Flutter] LayoutBuilder constraints: $constraints');
          return ClipRect(
            child: CustomPaint(
              painter: ChartPainter(
                xAxis: _xAxis,
                yAxis: _yAxis,
                series: _series,
                backgroundColor: _backgroundColor,
                showMajorGridLines: _showMajorGridLines,
                showMinorGridLines: _showMinorGridLines,
                majorGridLineColor: _majorGridLineColor,
                minorGridLineColor: _minorGridLineColor,
              ),
              // Use SizedBox.expand() to fill available space
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }
}
