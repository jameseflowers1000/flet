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

/// Series configuration model parsed from JSON.
class SeriesModel {
  final String type; // "fast_line", "scatter", "mountain"
  final String? seriesId;
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
  
  // For mountain/area series
  final Color? fillColor;
  final Color? gradientStartColor;
  final Color? gradientEndColor;
  final double zeroLineY;

  SeriesModel({
    required this.type,
    this.seriesId,
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
    this.fillColor,
    this.gradientStartColor,
    this.gradientEndColor,
    this.zeroLineY = 0.0,
  });

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

  static Color _parseColor(String? colorStr, Color? defaultColor) {
    if (colorStr == null) return defaultColor ?? Colors.grey;
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      } else if (hex.length == 8) {
        // Already has alpha, but in format AARRGGBB
      }
      return Color(int.parse(hex, radix: 16));
    }
    return defaultColor ?? Colors.grey;
  }
}
