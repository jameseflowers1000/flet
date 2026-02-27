import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Static service for MicroPython WASM interop.
///
/// Calls into window._epyxMicroPython (defined in micropython_bridge.js).
class MicroPythonService {
  MicroPythonService._();

  /// Get the bridge namespace, or null if not loaded.
  static JSObject? get _ns {
    final ns = globalContext['_epyxMicroPython'];
    if (ns == null || !ns.isA<JSObject>()) return null;
    return ns as JSObject;
  }

  /// Call a method on the bridge namespace by name.
  /// Returns the raw JSAny? result, or null if method not found.
  static JSAny? _call(String method, [List<JSAny?>? args]) {
    final ns = _ns;
    if (ns == null) throw StateError('micropython_bridge.js not loaded');
    final fn = ns[method];
    if (fn == null || !fn.isA<JSFunction>()) {
      throw StateError('_epyxMicroPython.$method not found');
    }
    final f = fn as JSFunction;
    if (args == null || args.isEmpty) {
      return f.callAsFunction(null);
    } else if (args.length == 1) {
      return f.callAsFunction(null, args[0]);
    } else if (args.length == 2) {
      return f.callAsFunction(null, args[0], args[1]);
    } else {
      return f.callAsFunction(null, args[0], args[1], args[2]);
    }
  }

  /// Convert a JSAny? to a Dart string, handling various JS types.
  static String _jsToString(JSAny? value) {
    if (value == null) return '';
    if (value.isA<JSString>()) return (value as JSString).toDart;
    // Fallback: use JS String() conversion via dartify
    return value.dartify()?.toString() ?? '';
  }

  /// Initialize the MicroPython WASM runtime.
  ///
  /// Returns a Future that completes when the runtime is ready.
  /// Safe to call multiple times — subsequent calls return immediately.
  static Future<void> init() async {
    final result = _call('init');
    if (result != null && result.isA<JSPromise>()) {
      await (result as JSPromise).toDart;
    }
  }

  /// Whether the MicroPython runtime is loaded and ready.
  static bool get isReady {
    final ns = _ns;
    if (ns == null) return false;
    final ready = ns['ready'];
    if (ready == null) return false;
    // Handle both JSBoolean and other truthy values
    if (ready.isA<JSBoolean>()) return (ready as JSBoolean).toDart;
    return ready.dartify() == true;
  }

  /// Evaluate a Python expression with the given JSON context.
  ///
  /// Returns the decoded JSON result. The Python code has access to a `ctx`
  /// dict and common builtins (len, sum, min, max, etc.).
  static dynamic eval(String code, [Map<String, dynamic>? context]) {
    final contextJson = jsonEncode(context ?? {});
    final result = _call('eval', [code.toJS, contextJson.toJS]);
    final jsonStr = _jsToString(result);
    if (jsonStr.isEmpty) return null;
    return jsonDecode(jsonStr);
  }

  /// Format a value using a Python f-string with context variables unpacked
  /// as top-level names (e.g., `y` not `ctx['y']`).
  ///
  /// Returns the formatted string, or null on error / not ready.
  static String? fmt(String code, [Map<String, dynamic>? context]) {
    final contextJson = jsonEncode(context ?? {});
    final result = _call('fmt', [code.toJS, contextJson.toJS]);
    final jsonStr = _jsToString(result);
    if (jsonStr.isEmpty) return null;
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map && decoded.containsKey('__error__')) return null;
    if (decoded is String) return decoded;
    return decoded?.toString();
  }

  /// Execute a two-phase eval: run exec_body statements, then evaluate
  /// eval_expr and return the result. Context is unpacked as top-level vars.
  ///
  /// Used by the render plane for client-side evaluation of EScalar live
  /// properties (display_code, color_code, etc.).
  ///
  /// Returns the decoded JSON result, or null on error / not ready.
  static dynamic execEval(String execBody, String evalExpr,
      [Map<String, dynamic>? context]) {
    final contextJson = jsonEncode(context ?? {});
    final result =
        _call('execEval', [execBody.toJS, evalExpr.toJS, contextJson.toJS]);
    final jsonStr = _jsToString(result);
    if (jsonStr.isEmpty) return null;
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map && decoded.containsKey('__error__')) return null;
    return decoded;
  }

  /// Execute Python statements (define functions, load modules, etc.).
  static void exec(String code) {
    _call('exec', [code.toJS]);
  }

  /// Get the last error message from the MicroPython runtime.
  static String getError() {
    try {
      final result = _call('getError');
      return _jsToString(result);
    } catch (_) {
      return 'Bridge not loaded';
    }
  }
}
