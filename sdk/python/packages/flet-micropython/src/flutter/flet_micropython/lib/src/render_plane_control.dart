import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'micropython_service.dart'
    if (dart.library.io) 'micropython_service_native.dart';

/// Per-control optimistic binding: listens to a Slider sub-control and
/// evaluates display code locally via MicroPython on every value change.
class _OptimisticBinding {
  final int sliderId;
  final int textId;
  final String execBody;
  final String evalExpr;
  Map<String, dynamic> cachedCtx;
  VoidCallback? listener;

  _OptimisticBinding({
    required this.sliderId,
    required this.textId,
    required this.execBody,
    required this.evalExpr,
    required this.cachedCtx,
  });
}

/// Non-visual control that evaluates EScalar live properties client-side
/// via MicroPython, enabling 60fps display updates without container round-trips.
///
/// Reads two JSON string properties from the container:
///   - `render_code`: code projections per control (changes rarely)
///   - `render_ctx`:  context values per control (changes every recalc)
///
/// For each control with code projections, calls MicroPythonService.execEval()
/// and pushes results to the target Flet control via FletBackend.updateControl().
///
/// Phase 4 — Optimistic Local Evaluation:
/// When a display property depends only on `_self_*` values, a ChangeNotifier
/// listener is attached to the Slider sub-control. On every slider drag tick,
/// MicroPython evaluates the display code with the new value immediately,
/// producing 60fps updates with zero container round-trip.
class RenderPlaneControl extends StatefulWidget {
  final Control control;

  const RenderPlaneControl({
    super.key,
    required this.control,
  });

  @override
  State<RenderPlaneControl> createState() => _RenderPlaneControlState();
}

class _RenderPlaneControlState extends State<RenderPlaneControl> {
  String? _lastRenderCode;
  String? _lastRenderCtx;

  // Parsed code projections: controlId → {propName → {exec, eval, deps}}
  Map<String, Map<String, Map<String, dynamic>>> _codeMap = {};

  // Parsed _meta per control: controlId → {slider_id, text_id}
  Map<String, Map<String, dynamic>> _metaMap = {};

  // Optimistic bindings: controlId → binding
  Map<String, _OptimisticBinding> _bindings = {};

  @override
  void initState() {
    super.initState();
    _processUpdates();
  }

  @override
  void didUpdateWidget(covariant RenderPlaneControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _processUpdates();
  }

  @override
  void dispose() {
    _teardownBindings();
    super.dispose();
  }

  void _processUpdates() {
    final renderCode = widget.control.getString("render_code");
    final renderCtx = widget.control.getString("render_ctx");

    // Parse code map if changed
    if (renderCode != _lastRenderCode) {
      _lastRenderCode = renderCode;
      _parseCodeMap(renderCode);
      _setupOptimisticBindings();
    }

    // Evaluate if context changed
    if (renderCtx != _lastRenderCtx) {
      _lastRenderCtx = renderCtx;
      _evaluateAll(renderCtx);
    }
  }

  void _parseCodeMap(String? renderCodeJson) {
    _codeMap = {};
    _metaMap = {};
    if (renderCodeJson == null || renderCodeJson.isEmpty) return;

    try {
      final parsed = jsonDecode(renderCodeJson) as Map<String, dynamic>;
      for (final entry in parsed.entries) {
        final controlId = entry.key;
        final props = entry.value as Map<String, dynamic>;

        // Extract _meta if present
        if (props.containsKey('_meta')) {
          _metaMap[controlId] = props['_meta'] as Map<String, dynamic>;
        }

        final propMap = <String, Map<String, dynamic>>{};
        for (final propEntry in props.entries) {
          final propName = propEntry.key;
          if (propName == '_meta') continue; // skip meta
          final code = propEntry.value as Map<String, dynamic>;
          propMap[propName] = {
            'exec': code['exec'] as String?,
            'eval': code['eval'] as String?,
            'deps': code['deps'] as List<dynamic>?,
          };
        }
        _codeMap[controlId] = propMap;
      }
    } catch (e) {
      debugPrint('[RenderPlane] ERROR parsing render_code: $e');
    }
  }

  // -----------------------------------------------------------------------
  // Optimistic bindings: slider listener → immediate MicroPython eval
  // -----------------------------------------------------------------------

  void _setupOptimisticBindings() {
    _teardownBindings();

    if (!mounted) return;
    final backend = FletBackend.of(context);

    for (final entry in _codeMap.entries) {
      final controlId = entry.key;
      final props = entry.value;
      final meta = _metaMap[controlId];
      if (meta == null) continue;

      final sliderId = meta['slider_id'];
      final textId = meta['text_id'];
      if (sliderId == null || textId == null) continue;

      // Check if display property is eligible (only _self_* deps)
      final displayCode = props['display'];
      if (displayCode == null) continue;
      final evalExpr = displayCode['eval'] as String?;
      if (evalExpr == null || evalExpr.isEmpty) continue;
      final deps = displayCode['deps'] as List<dynamic>?;
      if (deps == null || deps.isEmpty) continue;
      if (!deps.every((d) => d.toString().startsWith('_self_'))) continue;

      final sliderIdInt = int.parse(sliderId.toString());
      final sliderControl = backend.controlsIndex.get(sliderIdInt);
      if (sliderControl == null) continue;

      final binding = _OptimisticBinding(
        sliderId: sliderIdInt,
        textId: int.parse(textId.toString()),
        execBody: displayCode['exec'] as String? ?? '',
        evalExpr: evalExpr,
        cachedCtx: {},
      );

      void listener() => _onSliderChanged(controlId, binding);
      binding.listener = listener;
      sliderControl.addListener(listener);
      _bindings[controlId] = binding;
    }
  }

  void _teardownBindings() {
    if (_bindings.isEmpty) return;
    // Context may not be available during dispose, so use try
    FletBackend? backend;
    try {
      backend = FletBackend.of(context);
    } catch (_) {}

    for (final binding in _bindings.values) {
      if (binding.listener != null && backend != null) {
        final ctrl = backend.controlsIndex.get(binding.sliderId);
        ctrl?.removeListener(binding.listener!);
      }
    }
    _bindings.clear();
  }

  /// Hot path: called on every slider ChangeNotifier tick during drag.
  /// Wrapped entirely in try/catch — any exception propagating out of here
  /// would corrupt the Slider's own notifyListeners() chain.
  void _onSliderChanged(String controlId, _OptimisticBinding binding) {
    try {
      if (!MicroPythonService.isReady) return;
      if (!mounted) return;

      // Don't eval until we have authoritative context from the container
      if (binding.cachedCtx.isEmpty) return;

      final backend = FletBackend.of(context);
      final sliderControl = backend.controlsIndex.get(binding.sliderId);
      if (sliderControl == null) return;

      final newValue = sliderControl.getDouble("value");
      if (newValue == null) return;

      // Update _self_value in cached context
      binding.cachedCtx['_self_value'] = newValue;

      final result = MicroPythonService.execEval(
          binding.execBody, binding.evalExpr, binding.cachedCtx);
      if (result != null) {
        final value = result is String ? result : result.toString();
        backend.updateControl(
          binding.textId,
          {'value': value},
          dart: true,
          python: false, // Don't send to container
          notify: true,  // Text widget must rebuild to show new value
        );
      }
    } catch (e) {
      debugPrint('[RenderPlane] optimistic eval error: $e');
    }
  }

  // -----------------------------------------------------------------------
  // Authoritative evaluation (container context arrives)
  // -----------------------------------------------------------------------

  void _evaluateAll(String? renderCtxJson) {
    if (_codeMap.isEmpty) return;
    if (renderCtxJson == null || renderCtxJson.isEmpty) return;

    if (!MicroPythonService.isReady) return;

    Map<String, dynamic> ctxMap;
    try {
      ctxMap = jsonDecode(renderCtxJson) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[RenderPlane] ERROR parsing render_ctx: $e');
      return;
    }

    // For each control with code projections
    for (final entry in _codeMap.entries) {
      final controlId = entry.key;
      final props = entry.value;
      final ctx = ctxMap[controlId] as Map<String, dynamic>?;
      if (ctx == null) continue;

      // Seed optimistic binding's cached context with authoritative values
      final binding = _bindings[controlId];
      if (binding != null) {
        binding.cachedCtx = Map<String, dynamic>.from(ctx);
      }

      // Evaluate each property
      for (final propEntry in props.entries) {
        final propName = propEntry.key;
        final code = propEntry.value;
        final execBody = code['exec'] as String? ?? '';
        final evalExpr = code['eval'] as String?;

        if (evalExpr == null || evalExpr.isEmpty) continue;

        try {
          final result = MicroPythonService.execEval(execBody, evalExpr, ctx);
          if (result != null) {
            _applyResult(int.parse(controlId), propName, result);
          }
        } catch (e) {
          debugPrint(
              '[RenderPlane] eval error for control $controlId.$propName: $e');
        }
      }
    }
  }

  void _applyResult(int controlId, String propName, dynamic result) {
    // Map property names to Flet control property names
    // display → value (for Text controls), others map directly
    final fletProp = propName == 'display' ? 'value' : propName;
    final value = result is String ? result : result.toString();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        FletBackend.of(context).updateControl(
          controlId,
          {fletProp: value},
          dart: true,
          python: false, // Don't loop back to container
          // notify intentionally false: _applyResult targets the parent
          // Container control (not the Text sub-control), so notifying
          // would force a Container rebuild with a corrupted value property.
          // The container's own property updates handle the authoritative
          // display; the render plane patches are a silent pre-seed.
        );
      } catch (e) {
        debugPrint(
            '[RenderPlane] Failed to update control $controlId.$fletProp: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
