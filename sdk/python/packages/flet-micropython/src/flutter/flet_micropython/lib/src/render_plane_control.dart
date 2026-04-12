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

/// Non-visual control that evaluates render plane projections client-side
/// via MicroPython, enabling 60fps display updates without container round-trips.
///
/// Reads two JSON string properties from the container:
///   - `render_code`: code projections per control (changes rarely)
///   - `render_ctx`:  context values per control (changes every recalc)
///
/// Schema for `render_code`:
///   {
///     "scalar123": {
///       "display": {"exec": ..., "eval": ..., "deps": [...]},   // legacy EScalar
///       "_meta": {"slider_id": ..., "text_id": ...}
///     },
///     "inkpad456": {
///       "render": {"exec": ..., "eval": ..., "deps": [...], "params": []}   // new
///     },
///     "tab789": {
///       "render": {"exec": ..., "eval": ..., "deps": [...],
///                  "params": ["value", "row", "col_name"]},
///       "on_key": {"exec": ..., "eval": ..., "deps": [...],
///                  "params": ["key", "modifiers", "row", "col"]}
///     }
///   }
///
/// For legacy EScalar projections (no `params`), this widget evaluates them
/// itself when context changes and pushes results to target controls via
/// FletBackend.updateControl(). The slider→text optimistic binding is the
/// 60fps fast path.
///
/// For new function-style projections (with `params`), this widget acts as
/// a registry: consumer widgets (SuperPlot, EpyxGrid) call the static service
/// API [getProjection] and [getContext] to fetch their data, then evaluate
/// locally with their per-call context.
class RenderPlaneControl extends StatefulWidget {
  final Control control;

  const RenderPlaneControl({
    super.key,
    required this.control,
  });

  @override
  State<RenderPlaneControl> createState() => _RenderPlaneControlState();

  // ─────────────────────────────────────────────────────────────────────────
  // Static service API for consumer widgets (SuperPlot, EpyxGrid, etc.)
  // ─────────────────────────────────────────────────────────────────────────

  /// Latest parsed projections, keyed by control_id then function name.
  /// Each inner map: {exec, eval, deps, params?}.
  static final Map<String, Map<String, Map<String, dynamic>>> _registryCode = {};

  /// Latest parsed closure contexts, keyed by control_id.
  static final Map<String, Map<String, dynamic>> _registryCtx = {};

  /// Listeners notified when a control's projection or context changes.
  static final Map<String, List<VoidCallback>> _registryListeners = {};

  /// Fetch the projection for a (control_id, func_name) pair.
  /// Returns null if not registered.
  static Map<String, dynamic>? getProjection(String controlId, String funcName) {
    return _registryCode[controlId]?[funcName];
  }

  /// Fetch the closure context for a control_id.
  /// Returns null if not registered.
  static Map<String, dynamic>? getContext(String controlId) {
    return _registryCtx[controlId];
  }

  /// Register a callback that fires when the projection or context for the
  /// given control_id changes. Returns an unregister function.
  static VoidCallback addListener(String controlId, VoidCallback listener) {
    final list = _registryListeners.putIfAbsent(controlId, () => []);
    list.add(listener);
    return () {
      list.remove(listener);
      if (list.isEmpty) _registryListeners.remove(controlId);
    };
  }

  /// Internal: notify listeners that a control's projection or context changed.
  static void _notifyListeners(String controlId) {
    final list = _registryListeners[controlId];
    if (list == null) return;
    for (final cb in List<VoidCallback>.from(list)) {
      try {
        cb();
      } catch (e) {
        debugPrint('[RenderPlane] listener error for $controlId: $e');
      }
    }
  }
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
    // Clear the static registry of entries we owned
    for (final id in _codeMap.keys) {
      RenderPlaneControl._registryCode.remove(id);
      RenderPlaneControl._registryCtx.remove(id);
      RenderPlaneControl._notifyListeners(id);
    }
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
    final previousIds = Set<String>.from(_codeMap.keys);
    _codeMap = {};
    _metaMap = {};

    // Clear the static registry of any previous entries we owned
    for (final id in previousIds) {
      RenderPlaneControl._registryCode.remove(id);
    }

    if (renderCodeJson == null || renderCodeJson.isEmpty) {
      // Notify previous listeners that their control is gone
      for (final id in previousIds) {
        RenderPlaneControl._notifyListeners(id);
      }
      return;
    }

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
          // Preserve params field if present (new function-style projections)
          propMap[propName] = {
            'exec': code['exec'] as String?,
            'eval': code['eval'] as String?,
            'deps': code['deps'] as List<dynamic>?,
            if (code.containsKey('params')) 'params': code['params'] as List<dynamic>?,
          };
        }
        _codeMap[controlId] = propMap;
        // Mirror into the static registry for consumer widgets
        RenderPlaneControl._registryCode[controlId] = propMap;
      }
    } catch (e) {
      debugPrint('[RenderPlane] ERROR parsing render_code: $e');
    }

    // Notify all affected listeners (previous + new)
    final allIds = previousIds.union(_codeMap.keys.toSet());
    for (final id in allIds) {
      RenderPlaneControl._notifyListeners(id);
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
    // Always update the static context registry, even if no projections
    // exist locally. Consumer widgets read from the registry independently.
    final previousCtxIds = Set<String>.from(RenderPlaneControl._registryCtx.keys);
    RenderPlaneControl._registryCtx.clear();

    Map<String, dynamic> ctxMap = {};
    if (renderCtxJson != null && renderCtxJson.isNotEmpty) {
      try {
        ctxMap = jsonDecode(renderCtxJson) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('[RenderPlane] ERROR parsing render_ctx: $e');
        return;
      }
      for (final entry in ctxMap.entries) {
        if (entry.value is Map<String, dynamic>) {
          RenderPlaneControl._registryCtx[entry.key] =
              entry.value as Map<String, dynamic>;
        }
      }
    }

    // Notify listeners whose context changed
    final affectedIds =
        previousCtxIds.union(RenderPlaneControl._registryCtx.keys.toSet());
    for (final id in affectedIds) {
      RenderPlaneControl._notifyListeners(id);
    }

    if (_codeMap.isEmpty) return;
    if (!MicroPythonService.isReady) return;

    // For each control with code projections, evaluate the LEGACY-style
    // projections here (no params). Function-style projections (with params)
    // are evaluated by consumer widgets via the static service API.
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

      // Evaluate each non-function property (legacy EScalar style)
      for (final propEntry in props.entries) {
        final propName = propEntry.key;
        final code = propEntry.value;
        // Skip function-style projections — those have params and are
        // evaluated by their consumer widgets, not here.
        if (code.containsKey('params')) continue;

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
