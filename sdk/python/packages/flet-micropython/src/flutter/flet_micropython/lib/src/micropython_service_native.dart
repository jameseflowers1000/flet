import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Typedefs for C function signatures.
typedef _InitC = Int32 Function(Uint32 heapSize);
typedef _InitDart = int Function(int heapSize);

typedef _EvalC = Pointer<Utf8> Function(
    Pointer<Utf8> code, Pointer<Utf8> contextJson);
typedef _EvalDart = Pointer<Utf8> Function(
    Pointer<Utf8> code, Pointer<Utf8> contextJson);

typedef _ExecC = Pointer<Utf8> Function(Pointer<Utf8> code);
typedef _ExecDart = Pointer<Utf8> Function(Pointer<Utf8> code);

typedef _IsReadyC = Int32 Function();
typedef _IsReadyDart = int Function();

typedef _GetErrorC = Pointer<Utf8> Function();
typedef _GetErrorDart = Pointer<Utf8> Function();

typedef _DeinitC = Void Function();
typedef _DeinitDart = void Function();

typedef _FreeC = Void Function(Pointer<Utf8> ptr);
typedef _FreeDart = void Function(Pointer<Utf8> ptr);

/// Native MicroPython service via dart:ffi.
///
/// Calls into libepyx_micropython (compiled from MicroPython embed sources).
/// Same API as the web MicroPythonService — init/eval/exec/isReady/getError.
class MicroPythonService {
  MicroPythonService._();

  static bool _initialized = false;
  static DynamicLibrary? _lib;

  // Lazy FFI function lookups.
  static late final _InitDart _initFn;
  static late final _EvalDart _evalFn;
  static late final _ExecDart _execFn;
  static late final _IsReadyDart _isReadyFn;
  static late final _GetErrorDart _getErrorFn;
  static late final _DeinitDart _deinitFn;
  static late final _FreeDart _freeFn;

  static DynamicLibrary _loadLibrary() {
    const libName = 'libepyx_micropython';
    if (Platform.isMacOS) {
      // Try the app bundle's Frameworks dir first (production), then
      // fall back to bare name (dev — works if DYLD_LIBRARY_PATH is set
      // or the dylib is in the working directory).
      try {
        final exe = Platform.resolvedExecutable;
        // exe is e.g. .../Flet.app/Contents/MacOS/Flet
        final frameworksDir = exe.substring(0, exe.lastIndexOf('/'))
            .replaceFirst('/MacOS', '/Frameworks');
        return DynamicLibrary.open('$frameworksDir/$libName.dylib');
      } catch (_) {
        return DynamicLibrary.open('$libName.dylib');
      }
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('$libName.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('epyx_micropython.dll');
    }
    if (Platform.isIOS) {
      return DynamicLibrary.process(); // static linking
    }
    if (Platform.isAndroid) {
      return DynamicLibrary.open('$libName.so');
    }
    throw UnsupportedError('Unsupported platform for MicroPython native');
  }

  static void _bindFunctions(DynamicLibrary lib) {
    _initFn = lib.lookupFunction<_InitC, _InitDart>('epyx_mp_init');
    _evalFn = lib.lookupFunction<_EvalC, _EvalDart>('epyx_mp_eval');
    _execFn = lib.lookupFunction<_ExecC, _ExecDart>('epyx_mp_exec');
    _isReadyFn = lib.lookupFunction<_IsReadyC, _IsReadyDart>('epyx_mp_is_ready');
    _getErrorFn =
        lib.lookupFunction<_GetErrorC, _GetErrorDart>('epyx_mp_get_error');
    _deinitFn = lib.lookupFunction<_DeinitC, _DeinitDart>('epyx_mp_deinit');
    _freeFn = lib.lookupFunction<_FreeC, _FreeDart>('epyx_mp_free');
  }

  /// Initialize the MicroPython runtime.
  ///
  /// Returns a Future that completes when the runtime is ready.
  /// Safe to call multiple times — subsequent calls return immediately.
  static Future<void> init() async {
    if (_initialized) return;

    _lib = _loadLibrary();
    _bindFunctions(_lib!);

    final result = _initFn(65536); // 64KB heap
    if (result != 0) {
      throw StateError('MicroPython native init failed (code $result)');
    }
    _initialized = true;
  }

  /// Whether the MicroPython runtime is loaded and ready.
  static bool get isReady {
    if (!_initialized) return false;
    return _isReadyFn() != 0;
  }

  /// Evaluate a Python expression with the given JSON context.
  ///
  /// Returns the decoded JSON result. The Python code has access to a `ctx`
  /// dict and common builtins (len, sum, min, max, etc.).
  static dynamic eval(String code, [Map<String, dynamic>? context]) {
    final contextJson = jsonEncode(context ?? {});
    final codePtr = code.toNativeUtf8();
    final ctxPtr = contextJson.toNativeUtf8();
    try {
      final resultPtr = _evalFn(codePtr.cast(), ctxPtr.cast());
      final jsonStr = resultPtr.cast<Utf8>().toDartString();
      _freeFn(resultPtr);
      if (jsonStr.isEmpty) return null;
      return jsonDecode(jsonStr);
    } finally {
      malloc.free(codePtr);
      malloc.free(ctxPtr);
    }
  }

  static bool _fmtBootstrapped = false;

  /// Bootstrap _cfmt and _epyx_fmt helpers in the native MicroPython runtime.
  /// Uses _json_loads/_json_dumps (the native build's custom JSON, not the
  /// json module which isn't available in the minimal embed config).
  static void _bootstrapFmt() {
    if (_fmtBootstrapped) return;

    // Define _cfmt (comma thousands formatter)
    _execSilent(
      'def _cfmt(value, decimals=2):\n'
      '    neg = value < 0\n'
      '    value = abs(value)\n'
      '    if decimals > 0:\n'
      '        s = str(round(value * (10 ** decimals)))\n'
      '        while len(s) <= decimals:\n'
      '            s = "0" + s\n'
      '        int_part = s[:-decimals]\n'
      '        dec_part = s[-decimals:]\n'
      '    else:\n'
      '        int_part = str(round(value))\n'
      '        dec_part = ""\n'
      '    groups = []\n'
      '    while int_part:\n'
      '        groups.append(int_part[-3:])\n'
      '        int_part = int_part[:-3]\n'
      '    result = ",".join(reversed(groups)) if groups else "0"\n'
      '    if dec_part:\n'
      '        result += "." + dec_part\n'
      '    return ("-" if neg else "") + result\n',
    );

    // Define _epyx_fmt (like _epyx_eval but unpacks context as top-level names)
    _execSilent(
      'def _epyx_fmt(code, ctx_json):\n'
      '    try:\n'
      '        ctx = _json_loads(ctx_json) if ctx_json else {}\n'
      '        _g = {\n'
      '            "cfmt": _cfmt,\n'
      '            "len": len, "sum": sum, "min": min, "max": max,\n'
      '            "abs": abs, "round": round,\n'
      '            "int": int, "float": float, "str": str, "bool": bool,\n'
      '            "list": list, "dict": dict, "tuple": tuple, "range": range,\n'
      '            "sorted": sorted, "reversed": reversed,\n'
      '            "enumerate": enumerate, "zip": zip,\n'
      '            "map": map, "filter": filter,\n'
      '            "any": any, "all": all,\n'
      '            "isinstance": isinstance, "type": type,\n'
      '            "True": True, "False": False, "None": None,\n'
      '        }\n'
      '        _g.update(ctx)\n'
      '        result = eval(code, {"__builtins__": _g}, _g)\n'
      '        print(_json_dumps(result))\n'
      '    except Exception as e:\n'
      '        print(_json_dumps({"__error__": str(e)}))\n',
    );

    _fmtBootstrapped = true;
  }

  /// Format a value using a Python f-string with context variables unpacked
  /// as top-level names (e.g., `y` not `ctx['y']`).
  ///
  /// Bootstraps _epyx_fmt in the native runtime on first call, then uses
  /// the C exec function to run it and capture stdout.
  static String? fmt(String code, [Map<String, dynamic>? context]) {
    if (!_initialized || !isReady) return null;

    try {
      _bootstrapFmt();
    } catch (_) {
      return null;
    }

    final contextJson = jsonEncode(context ?? {});
    // Escape triple-quotes in code/context to prevent injection
    final safeCode = code.replaceAll("'''", r"\'\'\'");
    final safeCtx = contextJson.replaceAll("'''", r"\'\'\'");

    final callCode = "_epyx_fmt('''$safeCode''', '''$safeCtx''')";
    final output = _execCapture(callCode);
    if (output == null || output.isEmpty) return null;

    final trimmed = output.trim();
    if (trimmed.isEmpty) return null;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded.containsKey('__error__')) return null;
      if (decoded is String) return decoded;
      return decoded?.toString();
    } catch (_) {
      return null;
    }
  }

  static bool _execEvalBootstrapped = false;

  /// Bootstrap _epyx_exec_eval helper in the native MicroPython runtime.
  static void _bootstrapExecEval() {
    if (_execEvalBootstrapped) return;

    // Ensure _cfmt is available (shared with fmt)
    _bootstrapFmt();

    _execSilent(
      'def _epyx_exec_eval(exec_code, eval_code, ctx_json):\n'
      '    try:\n'
      '        ctx = _json_loads(ctx_json) if ctx_json else {}\n'
      '        _g = {\n'
      '            "cfmt": _cfmt,\n'
      '            "len": len, "sum": sum, "min": min, "max": max,\n'
      '            "abs": abs, "round": round,\n'
      '            "int": int, "float": float, "str": str, "bool": bool,\n'
      '            "list": list, "dict": dict, "tuple": tuple, "range": range,\n'
      '            "sorted": sorted, "reversed": reversed,\n'
      '            "enumerate": enumerate, "zip": zip,\n'
      '            "map": map, "filter": filter,\n'
      '            "any": any, "all": all,\n'
      '            "isinstance": isinstance, "type": type,\n'
      '            "True": True, "False": False, "None": None,\n'
      '        }\n'
      '        _g.update(ctx)\n'
      '        if exec_code:\n'
      '            exec(exec_code, {"__builtins__": _g}, _g)\n'
      '        if eval_code:\n'
      '            result = eval(eval_code, {"__builtins__": _g}, _g)\n'
      '            print(_json_dumps(result))\n'
      '        else:\n'
      '            print(_json_dumps(None))\n'
      '    except Exception as e:\n'
      '        print(_json_dumps({"__error__": str(e)}))\n',
    );

    _execEvalBootstrapped = true;
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
    if (!_initialized || !isReady) return null;

    try {
      _bootstrapExecEval();
    } catch (_) {
      return null;
    }

    final contextJson = jsonEncode(context ?? {});
    // Escape triple-quotes in all three args to prevent injection
    final safeExec = execBody.replaceAll("'''", r"\'\'\'");
    final safeEval = evalExpr.replaceAll("'''", r"\'\'\'");
    final safeCtx = contextJson.replaceAll("'''", r"\'\'\'");

    final callCode =
        "_epyx_exec_eval('''$safeExec''', '''$safeEval''', '''$safeCtx''')";
    final output = _execCapture(callCode);
    if (output == null || output.isEmpty) return null;

    final trimmed = output.trim();
    if (trimmed.isEmpty) return null;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded.containsKey('__error__')) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// Execute Python statements (define functions, load modules, etc.).
  static void exec(String code) {
    final codePtr = code.toNativeUtf8();
    try {
      final resultPtr = _execFn(codePtr.cast());
      if (resultPtr.address != 0) {
        final errStr = resultPtr.cast<Utf8>().toDartString();
        _freeFn(resultPtr);
        throw StateError('MicroPython exec error: $errStr');
      }
    } finally {
      malloc.free(codePtr);
    }
  }

  /// Execute Python code via the C exec FFI, but DON'T throw on output.
  /// The C exec treats any stdout as an "error" return, but _epyx_fmt
  /// uses print() to return its result. This method captures that output.
  static String? _execCapture(String code) {
    final codePtr = code.toNativeUtf8();
    try {
      final resultPtr = _execFn(codePtr.cast());
      if (resultPtr.address != 0) {
        final str = resultPtr.cast<Utf8>().toDartString();
        _freeFn(resultPtr);
        return str;
      }
      return null;
    } finally {
      malloc.free(codePtr);
    }
  }

  /// Execute Python code silently — throws on output (real errors),
  /// used for bootstrapping definitions that produce no output.
  static void _execSilent(String code) {
    final codePtr = code.toNativeUtf8();
    try {
      final resultPtr = _execFn(codePtr.cast());
      if (resultPtr.address != 0) {
        final errStr = resultPtr.cast<Utf8>().toDartString();
        _freeFn(resultPtr);
        throw StateError('MicroPython exec error: $errStr');
      }
    } finally {
      malloc.free(codePtr);
    }
  }

  /// Get the last error message from the MicroPython runtime.
  static String getError() {
    if (!_initialized) return 'Not initialized';
    final resultPtr = _getErrorFn();
    final str = resultPtr.cast<Utf8>().toDartString();
    _freeFn(resultPtr);
    return str;
  }
}
