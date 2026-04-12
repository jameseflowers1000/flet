import 'dart:convert';
import 'dart:typed_data';

import 'package:flet/flet.dart';
import 'package:flet_micropython/flet_micropython.dart';
import 'package:flutter/material.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';

import 'debug_log.dart'
    if (dart.library.io) 'debug_log_io.dart';
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

  // Named data buffers pushed by EInk via EMatPlot.push_data()
  final DataBufferStore _dataBuffers = DataBufferStore();

  // Config-driven series from chart bridge evaluation via RenderPlane
  List<SeriesModel> _configSeries = [];
  List<Map<String, dynamic>> _configAnnotations = [];

  // Render state for draggable annotations → PaletteProvider formulas
  final Map<String, dynamic> _renderState = {};

  // RenderPlane subscription
  VoidCallback? _renderPlaneUnregister;
  String? _renderPlaneControlId;
  String? _lastRenderPlaneProjJson;

  // Chart styling from control
  Color _backgroundColor = const Color(0xFF1c1c1e);
  bool _showMajorGridLines = true;
  bool _showMinorGridLines = false;
  Color _majorGridLineColor = const Color(0xFF555555);
  Color _minorGridLineColor = const Color(0xFF333333);

  @override
  void initState() {
    super.initState();
    superplotLog('[SuperPlot] initState');
    _parseConfig();
    _subscribeRenderPlane();
  }

  @override
  void didUpdateWidget(covariant SuperPlotControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseConfig();
    _subscribeRenderPlane();
  }

  @override
  void dispose() {
    superplotLog('[SuperPlot] dispose — _configSeries=${_configSeries.length}, _series=${_series.length}');
    _renderPlaneUnregister?.call();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // Phase 3b — Subscribe to the shared RenderPlane registry. The container
  // pushes a projection of the spec_code's def render() function to the
  // RenderPlane keyed by our control id; when it changes (or when context
  // changes), we re-evaluate via MicroPython using the registered chart
  // bridge prelude (singleton named `chart`).
  // -----------------------------------------------------------------------
  void _subscribeRenderPlane() {
    final newId = widget.control.id?.toString();
    if (newId == _renderPlaneControlId) return; // already subscribed
    _renderPlaneUnregister?.call();
    _renderPlaneControlId = newId;
    if (newId == null) return;
    _renderPlaneUnregister = RenderPlaneControl.addListener(
      newId,
      _onRenderPlaneChanged,
    );
    // Run once to seed initial state if a projection already exists
    _onRenderPlaneChanged();
  }

  void _onRenderPlaneChanged() {
    final ctrlId = _renderPlaneControlId;
    if (ctrlId == null) return;
    final proj = RenderPlaneControl.getProjection(ctrlId, 'render');
    if (proj == null) return;

    // Skip redundant evals if the projection JSON hasn't changed AND
    // we successfully evaluated last time. We can't set _lastRenderPlaneProjJson
    // until AFTER a successful eval — otherwise a "not ready" deferred retry
    // would think the eval already happened and bail.
    final projJson = jsonEncode(proj);
    if (projJson == _lastRenderPlaneProjJson) return;

    if (!MicroPythonService.isReady) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _onRenderPlaneChanged();
      });
      return;
    }

    // Build the exec body: chart._reset() + the render function body.
    // Note: project_render_funcs splits the body into exec + eval (last
    // expression). We concatenate both as statements since chart.* calls
    // return None and we don't care about their return values — we only
    // care about chart._to_config() at the end.
    final exec = proj['exec'] as String? ?? '';
    final lastExpr = proj['eval'] as String?;
    final body = StringBuffer();
    body.writeln('chart._reset()');
    if (exec.isNotEmpty) body.writeln(exec);
    if (lastExpr != null && lastExpr.isNotEmpty) body.writeln(lastExpr);

    // Closure context — Phase 3 just passes any registered context for
    // this control_id. Future phases will populate it with doc-level
    // free vars referenced by the render function.
    final ctx = RenderPlaneControl.getContext(ctrlId) ?? <String, dynamic>{};
    final mergedCtx = <String, dynamic>{...ctx, ..._renderState};

    try {
      final result = MicroPythonService.execEval(
        body.toString(),
        'chart._to_config()',
        mergedCtx,
      );
      if (result is Map) {
        final configJson = jsonEncode(result);
        _parseChartConfig(configJson);
        _initRenderStateFromAnnotations();
        // Cache the JSON only after a successful eval — so a future
        // identical projection skips work, but failed/deferred evals
        // can be retried.
        _lastRenderPlaneProjJson = projJson;
        superplotLog(
            '[SuperPlot] RenderPlane SUCCESS: ${_configSeries.length} series, ${_configAnnotations.length} annotations');
        if (mounted) setState(() {});
      } else {
        superplotLog('[SuperPlot] RenderPlane eval returned $result');
      }
    } catch (e) {
      superplotLog('[SuperPlot] RenderPlane eval error: $e');
    }
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

    // Log state after parsing
    superplotLog('[SuperPlot] _parseConfig done: '
        'series=${_series.length}, configSeries=${_configSeries.length}, '
        'buffers=${_dataBuffers.length}(gen=${_dataBuffers.generation})');

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

    final allS = _allSeries;
    if (allS.isEmpty) {
      superplotLog('[SuperPlot] BUILD: NO SERIES — chart will be blank');
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

