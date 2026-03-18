import 'dart:convert';
import 'dart:typed_data';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';

import 'interactive_chart.dart';
import 'models/axis_model.dart';
import 'models/series_model.dart';

/// Main SuperPlot control widget.
///
/// Parses configuration from Flet control properties and renders
/// using CustomPainter for GPU-accelerated drawing.
class SuperPlotControl extends StatefulWidget {
  /// SuperPlot version - update this when making changes.
  /// Format: major.minor.patch
  static const String version = '0.1.03';

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
  AxisModel? _yAxis2; // Secondary Y axis (for dual-axis charts)
  List<SeriesModel> _series = [];
  List<Map<String, dynamic>> _annotations = [];
  bool _versionSent = false;

  // Named data buffers from series_code
  final DataBufferStore _dataBuffers = DataBufferStore();

  // Config-driven series from chart_config or plot_code_src (bridge API)
  List<SeriesModel> _configSeries = [];
  List<Map<String, dynamic>> _configAnnotations = [];

  // Render state for draggable annotations → PaletteProvider formulas
  final Map<String, dynamic> _renderState = {};

  // Last plot_code_src to avoid re-evaluation on unchanged code
  String? _lastPlotCodeSrc;

  // Plot context: container-computed values passed to plot_code evaluation
  Map<String, dynamic> _plotContext = {};
  String? _lastPlotContextJson;

  // Chart styling from control
  Color _backgroundColor = const Color(0xFF1c1c1e);
  bool _showMajorGridLines = true;
  bool _showMinorGridLines = false;
  Color _majorGridLineColor = const Color(0xFF555555);
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
    // Parse X axis — skip if plot_code bridge already set a config axis
    // (bridge config takes priority to preserve datetime/log types)
    final xAxisJson = widget.control.getString("x_axis");
    if (xAxisJson != null && xAxisJson.isNotEmpty && _configSeries.isEmpty) {
      try {
        _xAxis = AxisModel.fromJson(jsonDecode(xAxisJson));
      } catch (e) {
        debugPrint('[SuperPlot] ERROR parsing x_axis: $e');
      }
    }

    // Parse Y axis — same guard
    final yAxisJson = widget.control.getString("y_axis");
    if (yAxisJson != null && yAxisJson.isNotEmpty && _configSeries.isEmpty) {
      try {
        _yAxis = AxisModel.fromJson(jsonDecode(yAxisJson));
      } catch (e) {
        debugPrint('[SuperPlot] ERROR parsing y_axis: $e');
      }
    }

    // Parse series (design dict path)
    final seriesJson = widget.control.getString("series");
    if (seriesJson != null && seriesJson.isNotEmpty) {
      try {
        final seriesList = jsonDecode(seriesJson) as List;
        _series = seriesList.map((s) => SeriesModel.fromJson(s)).toList();
      } catch (e) {
        debugPrint('[SuperPlot] ERROR parsing series: $e');
      }
    }

    // Parse annotations (design dict path)
    final annotationsJson = widget.control.getString("annotations");
    if (annotationsJson != null && annotationsJson.isNotEmpty) {
      try {
        final annList = jsonDecode(annotationsJson) as List;
        _annotations = annList.cast<Map<String, dynamic>>();
      } catch (e) {
        debugPrint('[SuperPlot] ERROR parsing annotations: $e');
      }
    } else {
      _annotations = [];
    }

    // Parse named data buffers (series_code path)
    final dataBuffersJson = widget.control.getString("data_buffers");
    bool dataBuffersChanged = false;
    if (dataBuffersJson != null && dataBuffersJson.isNotEmpty) {
      try {
        final oldCount = _dataBuffers.length;
        _dataBuffers.parseJson(dataBuffersJson);
        dataBuffersChanged = _dataBuffers.length != oldCount || oldCount == 0;
      } catch (e) {
        debugPrint('[SuperPlot] ERROR parsing data_buffers: $e');
      }
    }

    // Parse chart_config (bridge API / legacy container-eval path)
    final chartConfigJson = widget.control.getString("chart_config");
    if (chartConfigJson != null && chartConfigJson.isNotEmpty) {
      try {
        _parseChartConfig(chartConfigJson);
      } catch (e) {
        debugPrint('[SuperPlot] ERROR parsing chart_config: $e');
      }
    }

    // Parse plot_context (container-computed values for plot_code evaluation)
    final plotContextJson = widget.control.getString("plot_context");
    bool contextChanged = false;
    if (plotContextJson != null && plotContextJson.isNotEmpty) {
      if (plotContextJson != _lastPlotContextJson) {
        _lastPlotContextJson = plotContextJson;
        try {
          _plotContext = jsonDecode(plotContextJson) as Map<String, dynamic>;
          contextChanged = true;
        } catch (e) {
          debugPrint('[SuperPlot] ERROR parsing plot_context: $e');
        }
      }
    } else if (_lastPlotContextJson != null) {
      _lastPlotContextJson = null;
      _plotContext = {};
      contextChanged = true;
    }

    // Evaluate plot_code_src via client MicroPython (takes priority over chart_config)
    final plotCodeSrc = widget.control.getString("plot_code_src");
    if (plotCodeSrc != null && plotCodeSrc.isNotEmpty) {
      if (plotCodeSrc != _lastPlotCodeSrc || contextChanged || dataBuffersChanged) {
        print('[SuperPlot] plot_code_src received (${plotCodeSrc.length} chars), evaluating...');
        _lastPlotCodeSrc = plotCodeSrc;
        _evaluatePlotCode(plotCodeSrc);
      }
    } else {
      if (_lastPlotCodeSrc != null) {
        print('[SuperPlot] plot_code_src cleared');
      }
      _lastPlotCodeSrc = null;
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

  void _parseChartConfig(String configJson) {
    final config = jsonDecode(configJson) as Map<String, dynamic>;

    // Parse config series
    final seriesList = config['series'] as List? ?? [];
    _configSeries = seriesList
        .map((s) => SeriesModel.fromConfigJson(s as Map<String, dynamic>))
        .toList();

    // Parse config axes — apply to x/y axes if defined
    // Supports multiple Y axes: first Y → _yAxis (right), second Y → _yAxis2 (left)
    final axesList = config['axes'] as List? ?? [];
    bool primaryYSet = false;
    _yAxis2 = null;
    for (final axisJson in axesList) {
      final ax = axisJson as Map<String, dynamic>;
      final id = ax['id'] as String? ?? '';
      final align = ax['align'] as String? ?? 'left';
      if (id.startsWith('x')) {
        _xAxis = AxisModel(
          id: id,
          type: ax['type'] as String? ?? 'numeric',
          axisTitle: ax['title'] as String?,
          labelFormat: ax['label_format'] as String? ?? '{:.2f}',
        );
      } else if (id.startsWith('y')) {
        final axisModel = AxisModel(
          id: id,
          type: ax['type'] as String? ?? 'numeric',
          axisTitle: ax['title'] as String?,
          axisAlignment: align,
          labelFormat: ax['label_format'] as String? ?? '{:.2f}',
        );
        if (!primaryYSet) {
          _yAxis = axisModel;
          primaryYSet = true;
        } else {
          _yAxis2 = axisModel;
        }
      }
    }

    // Parse config annotations
    _configAnnotations = (config['annotations'] as List? ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// Evaluate plot_code source via client-side MicroPython.
  ///
  /// Concatenates BRIDGE_SOURCE + plotCode, evaluates via execEval,
  /// and parses the resulting JSON into series/axis/annotation models.
  void _evaluatePlotCode(String plotCode) {
    if (!MicroPythonService.isReady) {
      print('[SuperPlot] MicroPython not ready, deferring plot_code eval');
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && _lastPlotCodeSrc == plotCode) {
          _evaluatePlotCode(plotCode);
        }
      });
      return;
    }
    print('[SuperPlot] evaluating plot_code (${plotCode.length} chars) via MicroPython');
    try {
      final execBody = '$_bridgeSource\n$plotCode';
      final ctx = <String, dynamic>{..._plotContext, ..._renderState};
      final result = MicroPythonService.execEval(
        execBody, 'chart._to_config()', ctx);
      if (result is Map) {
        // MicroPython returns dict → _epyx_exec_eval serializes → Dart decodes to Map
        final configJson = jsonEncode(result);
        _parseChartConfig(configJson);
        _initRenderStateFromAnnotations();
        print('[SuperPlot] plot_code SUCCESS: ${_configSeries.length} series, ${_configAnnotations.length} annotations');
        if (mounted) setState(() {});
      } else if (result is String) {
        // Fallback: if somehow a JSON string comes back
        _parseChartConfig(result);
        _initRenderStateFromAnnotations();
        print('[SuperPlot] plot_code SUCCESS (string path): ${_configSeries.length} series');
        if (mounted) setState(() {});
      } else {
        final err = MicroPythonService.getError();
        print('[SuperPlot] plot_code eval failed — result: $result, error: $err');
      }
    } catch (e) {
      print('[SuperPlot] EXCEPTION evaluating plot_code: $e');
      final err = MicroPythonService.getError();
      if (err.isNotEmpty) print('[SuperPlot] MicroPython error: $err');
    }
  }

  /// Initialize renderState from draggable annotation defaults.
  void _initRenderStateFromAnnotations() {
    for (final ann in _configAnnotations) {
      final type = ann['type'] as String? ?? '';
      final id = ann['id'] as String?;
      if (id == null) continue;
      if (type == 'draggable_hline') {
        _renderState.putIfAbsent(id, () => (ann['y'] as num?)?.toDouble() ?? 0.0);
      } else if (type == 'draggable_vline') {
        _renderState.putIfAbsent(id, () => (ann['x'] as num?)?.toDouble() ?? 0.0);
      }
    }
  }

  /// Merge design-dict series with config series.
  List<SeriesModel> get _allSeries {
    if (_configSeries.isEmpty) return _series;
    if (_series.isEmpty) return _configSeries;
    return [..._series, ..._configSeries];
  }

  /// Merge design-dict annotations with config annotations.
  List<Map<String, dynamic>> get _allAnnotations {
    if (_configAnnotations.isEmpty) return _annotations;
    if (_annotations.isEmpty) return _configAnnotations;
    return [..._annotations, ..._configAnnotations];
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
    // Send version to Python once
    if (!_versionSent) {
      _versionSent = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FletBackend.of(context).updateControl(
          widget.control.id,
          {'runtime_version': SuperPlotControl.version},
        );
      });
    }

    return LayoutControl(
      control: widget.control,
      child: ClipRect(
        child: InteractiveChart(
          xAxis: _xAxis,
          yAxis: _yAxis,
          yAxis2: _yAxis2,
          series: _allSeries,
          dataBuffers: _dataBuffers,
          backgroundColor: _backgroundColor,
          showMajorGridLines: _showMajorGridLines,
          showMinorGridLines: _showMinorGridLines,
          majorGridLineColor: _majorGridLineColor,
          minorGridLineColor: _minorGridLineColor,
          annotations: _allAnnotations,
          renderState: _renderState,
          onRenderStateChanged: () {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }
}

/// ChartBridge Python source — prepended to plot_code for MicroPython evaluation.
/// This is an exact copy of BRIDGE_SOURCE from bridge.py.
/// Must work in MicroPython (no dataclasses, no typing, no numpy).
const String _bridgeSource = '''
class ChartBridge:
    def __init__(self):
        self._series = []
        self._axes = []
        self._legend = None
        self._annotations = []

    def line(self, x_col, y_col, color="#4083FF", name=None, width=2,
             y_axis="y0", draw_mode="linear", opacity=1.0,
             point_marker=None, tooltip_format=None, color_formula=None,
             dash_pattern=None):
        self._series.append({
            "type": "line", "x_col": x_col, "y_col": y_col,
            "color": color, "name": name, "width": width,
            "y_axis": y_axis, "draw_mode": draw_mode, "opacity": opacity,
            "point_marker": point_marker, "tooltip_format": tooltip_format,
            "color_formula": color_formula, "dash_pattern": dash_pattern,
        })

    def scatter(self, x_col, y_col, color="#FF6600", name=None, size=8,
                marker="circle", y_axis="y0", opacity=1.0, tooltip_format=None,
                color_formula=None):
        self._series.append({
            "type": "scatter", "x_col": x_col, "y_col": y_col,
            "color": color, "name": name, "size": size,
            "marker": marker, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format, "color_formula": color_formula,
        })

    def mountain(self, x_col, y_col, color="#4083FF", fill_color=None,
                 name=None, width=2, y_axis="y0", opacity=1.0,
                 zero_line_y=0.0, tooltip_format=None, stack_group=None):
        self._series.append({
            "type": "mountain", "x_col": x_col, "y_col": y_col,
            "color": color, "fill_color": fill_color, "name": name,
            "width": width, "y_axis": y_axis, "opacity": opacity,
            "zero_line_y": zero_line_y, "tooltip_format": tooltip_format,
            "stack_group": stack_group,
        })

    def column(self, x_col, y_col, fill_color="#4083FF", stroke_color=None,
               bar_width=0.7, name=None, y_axis="y0", opacity=1.0,
               tooltip_format=None, color_formula=None, stack_group=None):
        self._series.append({
            "type": "column", "x_col": x_col, "y_col": y_col,
            "fill_color": fill_color, "stroke_color": stroke_color,
            "bar_width": bar_width, "name": name, "y_axis": y_axis,
            "opacity": opacity, "tooltip_format": tooltip_format,
            "color_formula": color_formula, "stack_group": stack_group,
        })

    def candlestick(self, x_col, open_col, high_col, low_col, close_col,
                    up_color="#26A69A", down_color="#EF5350", wick_color=None,
                    body_width=0.6, name=None, y_axis="y0", opacity=1.0,
                    tooltip_format=None, color_formula=None):
        self._series.append({
            "type": "candlestick", "x_col": x_col,
            "open_col": open_col, "high_col": high_col,
            "low_col": low_col, "close_col": close_col,
            "up_color": up_color, "down_color": down_color,
            "wick_color": wick_color, "body_width": body_width,
            "name": name, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format, "color_formula": color_formula,
        })

    def band(self, x_col, y_high_col, y_low_col, fill_color="#2196F320",
             border_color=None, border_width=1.0, name=None, y_axis="y0",
             opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "band", "x_col": x_col,
            "y_high_col": y_high_col, "y_low_col": y_low_col,
            "fill_color": fill_color, "border_color": border_color,
            "border_width": border_width, "name": name,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def impulse(self, x_col, y_col, color="#4083FF", name=None, width=1.0,
                y_axis="y0", opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "impulse", "x_col": x_col, "y_col": y_col,
            "color": color, "name": name, "width": width,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def bubble(self, x_col, y_col, size_col, color="#4083FF", name=None,
               y_axis="y0", opacity=0.7, tooltip_format=None):
        self._series.append({
            "type": "bubble", "x_col": x_col, "y_col": y_col,
            "size_col": size_col, "color": color, "name": name,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def error_bar(self, x_col, y_col, error_high_col, error_low_col=None,
                  color="#4083FF", name=None, width=1.5, cap_width=6.0,
                  y_axis="y0", opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "error_bar", "x_col": x_col, "y_col": y_col,
            "error_high_col": error_high_col,
            "error_low_col": error_low_col if error_low_col else error_high_col,
            "color": color, "name": name, "width": width,
            "cap_width": cap_width, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def box_plot(self, x_col, min_col, q1_col, median_col, q3_col, max_col,
                 fill_color="#4083FF40", stroke_color="#4083FF",
                 median_color="#FFFFFF", name=None, y_axis="y0",
                 opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "box_plot", "x_col": x_col,
            "min_col": min_col, "q1_col": q1_col,
            "median_col": median_col, "q3_col": q3_col,
            "max_col": max_col, "fill_color": fill_color,
            "stroke_color": stroke_color, "median_color": median_color,
            "name": name, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def waterfall(self, x_col, y_col, up_color="#26A69A", down_color="#EF5350",
                  total_color="#4083FF", name=None, y_axis="y0",
                  opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "waterfall", "x_col": x_col, "y_col": y_col,
            "up_color": up_color, "down_color": down_color,
            "total_color": total_color, "name": name,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def histogram(self, y_col, bins=20, color="#4083FF", name=None,
                  y_axis="y0", opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "histogram", "y_col": y_col, "bins": bins,
            "color": color, "name": name, "y_axis": y_axis,
            "opacity": opacity, "tooltip_format": tooltip_format,
        })

    def axis(self, axis_id, title=None, type="numeric", align="left",
             range_mode="auto", visible_range_min=None, visible_range_max=None,
             log_base=10, label_format=None):
        self._axes.append({
            "id": axis_id, "title": title, "type": type,
            "align": align, "range_mode": range_mode,
            "visible_range_min": visible_range_min,
            "visible_range_max": visible_range_max,
            "log_base": log_base, "label_format": label_format,
        })

    def legend(self, position="top-left", checkboxes=True):
        self._legend = {"position": position, "checkboxes": checkboxes}

    def hline(self, y, color="#FFFF00", label=None, thickness=1.0, opacity=0.8):
        self._annotations.append({
            "type": "horizontal_line", "y": y, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def vline(self, x, color="#FFFF00", label=None, thickness=1.0, opacity=0.8):
        self._annotations.append({
            "type": "vertical_line", "x": x, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def draggable_hline(self, id, y, color="#FFFF00", label=None,
                        thickness=1.5, opacity=0.8):
        self._annotations.append({
            "type": "draggable_hline", "id": id, "y": y, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def draggable_vline(self, id, x, color="#FFFF00", label=None,
                        thickness=1.5, opacity=0.8):
        self._annotations.append({
            "type": "draggable_vline", "id": id, "x": x, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def _to_config(self):
        config = {
            "series": self._series,
            "axes": self._axes,
            "annotations": self._annotations,
        }
        if self._legend is not None:
            config["legend"] = self._legend
        return config

chart = ChartBridge()
''';
