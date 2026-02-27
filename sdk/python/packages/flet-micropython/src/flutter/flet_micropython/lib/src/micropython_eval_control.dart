import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'micropython_service.dart'
    if (dart.library.io) 'micropython_service_native.dart';

/// Non-visual control for evaluating Python code via MicroPython WASM.
///
/// Reads `code` and `context` string properties from the server,
/// calls MicroPythonService.eval(), and sends the result back.
class MicroPythonEvalControl extends StatefulWidget {
  final Control control;

  const MicroPythonEvalControl({
    super.key,
    required this.control,
  });

  @override
  State<MicroPythonEvalControl> createState() =>
      _MicroPythonEvalControlState();
}

class _MicroPythonEvalControlState extends State<MicroPythonEvalControl> {
  String? _lastCode;
  String? _lastContext;

  @override
  void initState() {
    super.initState();
    _evaluate();
  }

  @override
  void didUpdateWidget(covariant MicroPythonEvalControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _evaluate();
  }

  void _evaluate() {
    final code = widget.control.getString("code");
    final contextJson = widget.control.getString("context");

    // Only re-evaluate if code or context actually changed
    if (code == _lastCode && contextJson == _lastContext) return;
    _lastCode = code;
    _lastContext = contextJson;

    if (code == null || code.isEmpty) return;

    // Await init (idempotent) then evaluate — avoids race with WASM loading
    _doEvaluate(code, contextJson);
  }

  Future<void> _doEvaluate(String code, String? contextJson) async {
    try {
      await MicroPythonService.init();

      // On non-web platforms, WASM isn't available. Python already
      // evaluated server-side in __init__/evaluate(), so just skip.
      if (!MicroPythonService.isReady) return;

      Map<String, dynamic>? ctx;
      if (contextJson != null && contextJson.isNotEmpty) {
        ctx = jsonDecode(contextJson) as Map<String, dynamic>;
      }
      final result = MicroPythonService.eval(code, ctx);
      final resultJson = jsonEncode(result);

      _sendResult(resultJson);
    } catch (e) {
      _sendError(e.toString());
    }
  }

  void _sendResult(String resultJson) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FletBackend.of(context).updateControl(
        widget.control.id,
        {'result': resultJson},
      );
      FletBackend.of(context).triggerControlEvent(
        widget.control,
        'result',
        resultJson,
      );
    });
  }

  void _sendError(String error) {
    final errorJson = jsonEncode({'__error__': error});
    _sendResult(errorJson);
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
