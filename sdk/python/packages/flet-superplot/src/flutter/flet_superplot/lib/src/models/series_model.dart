import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Data points for a series.
class DataPoints {
  final Float64List xValues;
  final Float64List yValues;

  DataPoints({required this.xValues, required this.yValues});

  int get length => xValues.length;
  bool get isEmpty => xValues.isEmpty;
  bool get isNotEmpty => xValues.isNotEmpty;

  /// Decode from base64-encoded interleaved binary data.
  factory DataPoints.fromBase64(String base64Data, int count) {
    if (count == 0) {
      return DataPoints(
        xValues: Float64List(0),
        yValues: Float64List(0),
      );
    }

    final bytes = base64Decode(base64Data);
    final float64View = Float64List.view(bytes.buffer);

    final xValues = Float64List(count);
    final yValues = Float64List(count);

    for (int i = 0; i < count; i++) {
      xValues[i] = float64View[i * 2];
      yValues[i] = float64View[i * 2 + 1];
    }

    return DataPoints(xValues: xValues, yValues: yValues);
  }

  /// Get min/max of X values.
  (double, double) get xRange {
    if (isEmpty) return (0.0, 1.0);
    double min = xValues[0];
    double max = xValues[0];
    for (int i = 1; i < length; i++) {
      if (xValues[i] < min) min = xValues[i];
      if (xValues[i] > max) max = xValues[i];
    }
    return (min, max);
  }

  /// Get min/max of Y values.
  (double, double) get yRange {
    if (isEmpty) return (0.0, 1.0);
    double min = yValues[0];
    double max = yValues[0];
    for (int i = 1; i < length; i++) {
      if (yValues[i] < min) min = yValues[i];
      if (yValues[i] > max) max = yValues[i];
    }
    return (min, max);
  }
}

/// Named data buffer store — holds Float64Lists decoded from Base64.
/// Populated from the `data_buffers` Flet property.
class DataBufferStore {
  final Map<String, Float64List> _buffers = {};
  int generation = 0;

  Float64List? operator [](String name) => _buffers[name];
  void operator []=(String name, Float64List data) => _buffers[name] = data;
  bool containsKey(String name) => _buffers.containsKey(name);
  bool get isEmpty => _buffers.isEmpty;
  int get length => _buffers.length;

  void clear() => _buffers.clear();

  /// Decode a single base64-encoded Float64 array (NOT interleaved).
  static Float64List decodeBuffer(String base64Data, int count) {
    if (count == 0) return Float64List(0);
    final bytes = base64Decode(base64Data);
    // Create a copy to ensure proper alignment
    final aligned = Uint8List.fromList(bytes);
    return Float64List.view(aligned.buffer, 0, count);
  }

  /// Parse the data_buffers JSON into named Float64Lists.
  void parseJson(String json) {
    _buffers.clear();
    generation++;
    final Map<String, dynamic> map = jsonDecode(json);
    for (final entry in map.entries) {
      final bufInfo = entry.value as Map<String, dynamic>;
      final data = bufInfo['data'] as String? ?? '';
      final count = bufInfo['count'] as int? ?? 0;
      if (data.isNotEmpty && count > 0) {
        _buffers[entry.key] = decodeBuffer(data, count);
      }
    }
  }

  /// Get min/max of a named buffer.
  (double, double) range(String name) {
    final buf = _buffers[name];
    if (buf == null || buf.isEmpty) return (0.0, 1.0);
    double min = buf[0];
    double max = buf[0];
    for (int i = 1; i < buf.length; i++) {
      if (buf[i] < min) min = buf[i];
      if (buf[i] > max) max = buf[i];
    }
    return (min, max);
  }
}

/// Series configuration model parsed from JSON.
class SeriesModel {
  final String type; // "fast_line", "scatter", "mountain", "column", "candlestick", "band"
  final String? seriesId;
  final String? seriesName;
  final DataPoints? data;
  final Color strokeColor;
  final double strokeThickness;
  final String drawMode; // "linear", "step", "spline"
  final bool antiAliasing;
  final String pointMarkerType;
  final double pointMarkerSize;
  final Color pointMarkerColor;
  final double opacity;
  final bool isVisible;

  // Per-series tooltip format string (e.g. "${y:,.2f}", "{y:.1%}")
  final String? tooltipFormat;

  // For mountain/area series
  final Color? fillColor;
  final Color? gradientStartColor;
  final Color? gradientEndColor;
  final double zeroLineY;

  // --- Column references (bridge API path) ---
  final String? xCol;
  final String? yCol;
  // Candlestick columns
  final String? openCol;
  final String? highCol;
  final String? lowCol;
  final String? closeCol;
  // Band columns
  final String? yHighCol;
  final String? yLowCol;

  // Column series
  final double barWidth;

  // Candlestick series
  final Color? upColor;
  final Color? downColor;
  final Color? wickColor;
  final double bodyWidth;

  // Band series
  final Color? borderColor;
  final double borderWidth;

  // Bubble series
  final String? sizeCol;

  // Error bar series
  final String? errorHighCol;
  final String? errorLowCol;
  final double capWidth;

  // Histogram series
  final int bins;

  // Box plot columns
  final String? minCol;
  final String? q1Col;
  final String? medianCol;
  final String? q3Col;
  final String? maxCol;
  final Color? medianColor;

  // Waterfall series
  final Color? totalColor;

  // Stacking
  final String? stackGroup;

  // Dash pattern (e.g. [5, 3] for dashed lines)
  final List<double>? dashPattern;

  // PaletteProvider: per-point color formula (f-string evaluated via MicroPythonService.fmt)
  final String? colorFormula;

  // Multi-axis: which Y axis this series is bound to (default "y0" = primary left axis)
  final String yAxisId;

  SeriesModel({
    required this.type,
    this.seriesId,
    this.seriesName,
    this.data,
    this.strokeColor = const Color(0xFF4083FF),
    this.strokeThickness = 2.0,
    this.drawMode = "linear",
    this.antiAliasing = true,
    this.pointMarkerType = "none",
    this.pointMarkerSize = 8.0,
    this.pointMarkerColor = const Color(0xFF4083FF),
    this.opacity = 1.0,
    this.isVisible = true,
    this.tooltipFormat,
    this.fillColor,
    this.gradientStartColor,
    this.gradientEndColor,
    this.zeroLineY = 0.0,
    this.xCol,
    this.yCol,
    this.openCol,
    this.highCol,
    this.lowCol,
    this.closeCol,
    this.yHighCol,
    this.yLowCol,
    this.barWidth = 0.7,
    this.upColor,
    this.downColor,
    this.wickColor,
    this.bodyWidth = 0.6,
    this.borderColor,
    this.borderWidth = 1.0,
    this.sizeCol,
    this.errorHighCol,
    this.errorLowCol,
    this.capWidth = 6.0,
    this.bins = 20,
    this.minCol,
    this.q1Col,
    this.medianCol,
    this.q3Col,
    this.maxCol,
    this.medianColor,
    this.totalColor,
    this.stackGroup,
    this.dashPattern,
    this.colorFormula,
    this.yAxisId = 'y0',
  });

  /// Whether this series uses named data buffers (bridge API path).
  bool get usesNamedBuffers => xCol != null;

  /// Resolve data from named buffers, building DataPoints for rendering.
  DataPoints? resolveData(DataBufferStore buffers) {
    if (!usesNamedBuffers) return data;
    final xBuf = xCol != null ? buffers[xCol!] : null;
    final yBuf = yCol != null ? buffers[yCol!] : null;
    if (xBuf == null || yBuf == null) return null;
    final len = xBuf.length < yBuf.length ? xBuf.length : yBuf.length;
    return DataPoints(
      xValues: Float64List.sublistView(xBuf, 0, len),
      yValues: Float64List.sublistView(yBuf, 0, len),
    );
  }

  /// Get the Y-range considering all relevant Y columns.
  (double, double) yRangeFromBuffers(DataBufferStore buffers) {
    double min = double.infinity;
    double max = double.negativeInfinity;

    void updateRange(String? colName) {
      if (colName == null) return;
      final buf = buffers[colName];
      if (buf == null || buf.isEmpty) return;
      final (lo, hi) = _float64Range(buf);
      if (lo < min) min = lo;
      if (hi > max) max = hi;
    }

    switch (type) {
      case 'candlestick':
        updateRange(highCol);
        updateRange(lowCol);
        break;
      case 'band':
        updateRange(yHighCol);
        updateRange(yLowCol);
        break;
      case 'box_plot':
        updateRange(minCol);
        updateRange(maxCol);
        break;
      default:
        updateRange(yCol);
    }
    if (!min.isFinite) return (0.0, 1.0);
    return (min, max);
  }

  static (double, double) _float64Range(Float64List buf) {
    if (buf.isEmpty) return (0.0, 1.0);
    double min = buf[0], max = buf[0];
    for (int i = 1; i < buf.length; i++) {
      if (buf[i] < min) min = buf[i];
      if (buf[i] > max) max = buf[i];
    }
    return (min, max);
  }

  /// Parse from the traditional embedded-data series JSON (design dict path).
  factory SeriesModel.fromJson(Map<String, dynamic> json) {
    DataPoints? dataPoints;
    final dataJson = json['data'];
    if (dataJson != null) {
      final count = dataJson['count'] ?? 0;
      final base64 = dataJson['data_base64'] ?? '';
      if (count > 0 && base64.isNotEmpty) {
        dataPoints = DataPoints.fromBase64(base64, count);
      }
    }

    return SeriesModel(
      type: json['type'] ?? 'fast_line',
      seriesId: json['series_id'],
      seriesName: json['series_name'] ?? json['series_id'],
      data: dataPoints,
      strokeColor: _parseColor(json['stroke_color'], const Color(0xFF4083FF)),
      strokeThickness: (json['stroke_thickness'] ?? 2.0).toDouble(),
      drawMode: json['draw_mode'] ?? 'linear',
      antiAliasing: json['anti_aliasing'] ?? true,
      pointMarkerType: json['point_marker_type'] ?? 'none',
      pointMarkerSize: (json['point_marker_size'] ?? json['point_size'] ?? 8.0).toDouble(),
      pointMarkerColor: _parseColor(
          json['point_marker_color'] ?? json['point_color'],
          const Color(0xFF4083FF)),
      opacity: (json['opacity'] ?? 1.0).toDouble(),
      isVisible: json['is_visible'] ?? true,
      tooltipFormat: json['tooltip_format'],
      colorFormula: json['color_formula'] as String?,
      fillColor: json['fill_color'] != null ? _parseColor(json['fill_color'], null) : null,
      gradientStartColor: json['gradient_start_color'] != null
          ? _parseColor(json['gradient_start_color'], null)
          : null,
      gradientEndColor: json['gradient_end_color'] != null
          ? _parseColor(json['gradient_end_color'], null)
          : null,
      zeroLineY: (json['zero_line_y'] ?? 0.0).toDouble(),
    );
  }

  /// Parse from bridge API chart_config JSON (named buffer path).
  factory SeriesModel.fromConfigJson(Map<String, dynamic> json) {
    final type = json['type'] ?? 'line';
    // Map bridge type names to internal type names
    final mappedType = _bridgeTypeMap[type] ?? type;

    return SeriesModel(
      type: mappedType,
      seriesName: json['name'] as String?,
      xCol: json['x_col'] as String?,
      yCol: json['y_col'] as String?,
      openCol: json['open_col'] as String?,
      highCol: json['high_col'] as String?,
      lowCol: json['low_col'] as String?,
      closeCol: json['close_col'] as String?,
      yHighCol: json['y_high_col'] as String?,
      yLowCol: json['y_low_col'] as String?,
      strokeColor: _parseColor(json['color'] as String?, const Color(0xFF4083FF)),
      strokeThickness: (json['width'] as num?)?.toDouble() ?? 2.0,
      drawMode: json['draw_mode'] as String? ?? 'linear',
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      tooltipFormat: json['tooltip_format'] as String?,
      fillColor: json['fill_color'] != null
          ? _parseColor(json['fill_color'] as String?, null)
          : null,
      zeroLineY: (json['zero_line_y'] as num?)?.toDouble() ?? 0.0,
      barWidth: (json['bar_width'] as num?)?.toDouble() ?? 0.7,
      upColor: json['up_color'] != null
          ? _parseColor(json['up_color'] as String?, null)
          : null,
      downColor: json['down_color'] != null
          ? _parseColor(json['down_color'] as String?, null)
          : null,
      wickColor: json['wick_color'] != null
          ? _parseColor(json['wick_color'] as String?, null)
          : null,
      bodyWidth: (json['body_width'] as num?)?.toDouble() ?? 0.6,
      borderColor: json['border_color'] != null
          ? _parseColor(json['border_color'] as String?, null)
          : null,
      borderWidth: (json['border_width'] as num?)?.toDouble() ?? 1.0,
      pointMarkerType: json['marker'] as String? ?? 'none',
      pointMarkerSize: (json['size'] as num?)?.toDouble() ?? 8.0,
      pointMarkerColor: _parseColor(json['color'] as String?, const Color(0xFF4083FF)),
      colorFormula: json['color_formula'] as String?,
      yAxisId: json['y_axis'] as String? ?? 'y0',
      sizeCol: json['size_col'] as String?,
      errorHighCol: json['error_high_col'] as String?,
      errorLowCol: json['error_low_col'] as String?,
      capWidth: (json['cap_width'] as num?)?.toDouble() ?? 6.0,
      bins: (json['bins'] as num?)?.toInt() ?? 20,
      minCol: json['min_col'] as String?,
      q1Col: json['q1_col'] as String?,
      medianCol: json['median_col'] as String?,
      q3Col: json['q3_col'] as String?,
      maxCol: json['max_col'] as String?,
      medianColor: json['median_color'] != null
          ? _parseColor(json['median_color'] as String?, null)
          : null,
      totalColor: json['total_color'] != null
          ? _parseColor(json['total_color'] as String?, null)
          : null,
      stackGroup: json['stack_group'] as String?,
      dashPattern: (json['dash_pattern'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
    );
  }

  static const _bridgeTypeMap = {
    'line': 'fast_line',
    'scatter': 'scatter',
    'mountain': 'mountain',
    'column': 'column',
    'candlestick': 'candlestick',
    'band': 'band',
    'impulse': 'impulse',
    'bubble': 'bubble',
    'error_bar': 'error_bar',
    'histogram': 'histogram',
    'box_plot': 'box_plot',
    'waterfall': 'waterfall',
  };

  /// Public color parser for use by annotation rendering.
  static Color parseColorStatic(String? colorStr, Color defaultColor) {
    return _parseColor(colorStr, defaultColor);
  }

  static Color _parseColor(String? colorStr, Color? defaultColor) {
    if (colorStr == null) return defaultColor ?? Colors.grey;
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      } else if (hex.length == 8) {
        // Already has alpha, in format AARRGGBB
      }
      return Color(int.parse(hex, radix: 16));
    }
    return defaultColor ?? Colors.grey;
  }
}
