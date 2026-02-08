import 'package:flutter/material.dart';

/// Axis configuration model parsed from JSON.
class AxisModel {
  final String type; // "numeric" or "logarithmic"
  final String? axisTitle;
  final double? visibleRangeMin;
  final double? visibleRangeMax;
  final String autoRange; // "never", "once", "always"
  final double growByMin;
  final double growByMax;
  final String axisAlignment; // "left", "right", "top", "bottom"
  final String labelFormat;
  final int? majorTickCount;
  final int minorTickCount;
  final Color axisTitleColor;
  final Color axisLabelColor;
  final Color axisLineColor;
  final Color majorTickColor;
  final Color minorTickColor;
  final double axisTitleFontSize;
  final double axisLabelFontSize;
  final bool drawMajorTicks;
  final bool drawMinorTicks;
  final bool drawMajorGridLines;
  final bool drawMinorGridLines;
  final bool drawAxisLabels;
  final double? logarithmicBase;

  AxisModel({
    required this.type,
    this.axisTitle,
    this.visibleRangeMin,
    this.visibleRangeMax,
    this.autoRange = "always",
    this.growByMin = 0.1,
    this.growByMax = 0.1,
    this.axisAlignment = "left",
    this.labelFormat = "{:.2f}",
    this.majorTickCount,
    this.minorTickCount = 4,
    this.axisTitleColor = Colors.white,
    this.axisLabelColor = const Color(0xFFAAAAAA),
    this.axisLineColor = const Color(0xFF555555),
    this.majorTickColor = const Color(0xFF555555),
    this.minorTickColor = const Color(0xFF333333),
    this.axisTitleFontSize = 14.0,
    this.axisLabelFontSize = 12.0,
    this.drawMajorTicks = true,
    this.drawMinorTicks = true,
    this.drawMajorGridLines = true,
    this.drawMinorGridLines = false,
    this.drawAxisLabels = true,
    this.logarithmicBase,
  });

  factory AxisModel.fromJson(Map<String, dynamic> json) {
    return AxisModel(
      type: json['type'] ?? 'numeric',
      axisTitle: json['axis_title'],
      visibleRangeMin: json['visible_range_min']?.toDouble(),
      visibleRangeMax: json['visible_range_max']?.toDouble(),
      autoRange: json['auto_range'] ?? 'always',
      growByMin: (json['grow_by_min'] ?? 0.1).toDouble(),
      growByMax: (json['grow_by_max'] ?? 0.1).toDouble(),
      axisAlignment: json['axis_alignment'] ?? 'left',
      labelFormat: json['label_format'] ?? '{:.2f}',
      majorTickCount: json['major_tick_count'],
      minorTickCount: json['minor_tick_count'] ?? 4,
      axisTitleColor: _parseColor(json['axis_title_color'], Colors.white),
      axisLabelColor: _parseColor(json['axis_label_color'], const Color(0xFFAAAAAA)),
      axisLineColor: _parseColor(json['axis_line_color'], const Color(0xFF555555)),
      majorTickColor: _parseColor(json['major_tick_color'], const Color(0xFF555555)),
      minorTickColor: _parseColor(json['minor_tick_color'], const Color(0xFF333333)),
      axisTitleFontSize: (json['axis_title_font_size'] ?? 14.0).toDouble(),
      axisLabelFontSize: (json['axis_label_font_size'] ?? 12.0).toDouble(),
      drawMajorTicks: json['draw_major_ticks'] ?? true,
      drawMinorTicks: json['draw_minor_ticks'] ?? true,
      drawMajorGridLines: json['draw_major_grid_lines'] ?? true,
      drawMinorGridLines: json['draw_minor_grid_lines'] ?? false,
      drawAxisLabels: json['draw_axis_labels'] ?? true,
      logarithmicBase: json['logarithmic_base']?.toDouble(),
    );
  }

  static Color _parseColor(String? colorStr, Color defaultColor) {
    if (colorStr == null) return defaultColor;
    if (colorStr.startsWith('#')) {
      String hex = colorStr.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    }
    return defaultColor;
  }

  bool get isHorizontal => axisAlignment == 'top' || axisAlignment == 'bottom';
  bool get isLogarithmic => type == 'logarithmic';

  /// Create a copy with selected fields overridden.
  AxisModel copyWith({
    double? visibleRangeMin,
    double? visibleRangeMax,
    String? autoRange,
    double? growByMin,
    double? growByMax,
  }) {
    return AxisModel(
      type: type,
      axisTitle: axisTitle,
      visibleRangeMin: visibleRangeMin ?? this.visibleRangeMin,
      visibleRangeMax: visibleRangeMax ?? this.visibleRangeMax,
      autoRange: autoRange ?? this.autoRange,
      growByMin: growByMin ?? this.growByMin,
      growByMax: growByMax ?? this.growByMax,
      axisAlignment: axisAlignment,
      labelFormat: labelFormat,
      majorTickCount: majorTickCount,
      minorTickCount: minorTickCount,
      axisTitleColor: axisTitleColor,
      axisLabelColor: axisLabelColor,
      axisLineColor: axisLineColor,
      majorTickColor: majorTickColor,
      minorTickColor: minorTickColor,
      axisTitleFontSize: axisTitleFontSize,
      axisLabelFontSize: axisLabelFontSize,
      drawMajorTicks: drawMajorTicks,
      drawMinorTicks: drawMinorTicks,
      drawMajorGridLines: drawMajorGridLines,
      drawMinorGridLines: drawMinorGridLines,
      drawAxisLabels: drawAxisLabels,
      logarithmicBase: logarithmicBase,
    );
  }
}
