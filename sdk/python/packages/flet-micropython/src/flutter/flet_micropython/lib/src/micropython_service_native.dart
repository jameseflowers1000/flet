import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:io' as io;

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

  /// Registered prelude scripts, keyed by name. Each prelude is run via
  /// exec() once MicroPython is ready, defining bridge classes etc. in
  /// the global namespace. Names are arbitrary identifiers used for
  /// deduplication and debugging.
  static final Map<String, String> _preludes = {};

  /// Whether preludes have been loaded into the running MicroPython instance.
  static bool _preludesLoaded = false;

  /// Register a prelude script that will be exec'd in the MicroPython
  /// global namespace as soon as the runtime is ready. If the runtime is
  /// already ready, the prelude is exec'd immediately.
  ///
  /// Each control package (flet-superplot, flet-supertab, etc.) calls this
  /// at extension load time to install its bridge classes (chart, cell,
  /// field, ...). The bridge classes become singletons in MicroPython's
  /// global namespace, available to every render function evaluation.
  ///
  /// Calling registerPrelude with the same name twice replaces the entry.
  static void registerPrelude(String name, String source) {
    _preludes[name] = source;
    if (isReady && _preludesLoaded) {
      try {
        exec(source);
      } catch (_) {
        // Best effort — caller may not care about failures
      }
    }
  }

  /// Run all registered preludes in the MicroPython namespace.
  /// Called automatically by init() once the runtime is ready.
  static void _loadPreludes() {
    if (_preludesLoaded) return;
    if (!isReady) return;
    // Bootstrap exec_eval first — it defines _epyx_user_preludes which the
    // bridge preludes register themselves into. Without this, preludes load
    // BEFORE _epyx_user_preludes exists, and the registration silently fails.
    try {
      _bootstrapExecEval();
    } catch (_) {
      // If bootstrap fails, preludes will still load but won't be visible
      // to execEval.
    }
    for (final entry in _preludes.entries) {
      try {
        exec(entry.value);
        _diagExecEval('prelude "${entry.key}" exec OK (len=${entry.value.length})');
      } catch (e) {
        _diagExecEval('prelude "${entry.key}" exec FAILED: $e');
      }
      // Independently verify the prelude actually registered itself by
      // probing _epyx_user_preludes — execing a prelude can succeed but
      // its `try: _epyx_user_preludes['x'] = ... except: pass` block can
      // silently swallow errors that prevent registration.
      try {
        final probe = _execCapture(
          "print('PROBE_PRELUDE', '${entry.key}', "
          "'${entry.key}' in _epyx_user_preludes)");
        _diagExecEval('prelude "${entry.key}" registry probe: ${probe?.trim() ?? "<null>"}');
      } catch (_) {}
    }
    _preludesLoaded = true;
  }

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
  /// Returns a Future that completes when the runtime is ready and all
  /// registered preludes have been loaded into the global namespace.
  /// Safe to call multiple times — subsequent calls return immediately.
  static Future<void> init() async {
    if (_initialized) return;

    _lib = _loadLibrary();
    _bindFunctions(_lib!);

    final result = _initFn(1048576); // 1MB heap (was 64KB — caused MemoryError)
    if (result != 0) {
      throw StateError('MicroPython native init failed (code $result)');
    }
    _initialized = true;
    // Load any preludes registered before init completed
    _loadPreludes();
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
  static bool _cmdBootstrapped = false;

  /// Bootstrap the _Cmd command builder class and factory functions.
  /// Same API as micropython_bridge.js — chainable command pattern for on_key_code.
  static void _bootstrapCmd() {
    if (_cmdBootstrapped) return;
    _execSilent(
      'class _Cmd:\n'
      '    def _mkd(self, cmd, kw):\n'
      '        d = {"cmd": cmd}\n'
      '        d.update(kw)\n'
      '        return d\n'
      '    def __init__(self, cmd, **kw):\n'
      '        self._chain = [self._mkd(cmd, kw)]\n'
      '    def move(self, **kw):             self._chain.append(self._mkd("move", kw)); return self\n'
      '    def commit(self):                 self._chain.append({"cmd": "commit"}); return self\n'
      '    def initiate_editing(self, **kw): self._chain.append(self._mkd("initiate_editing", kw)); return self\n'
      '    def cancel_editing(self):         self._chain.append({"cmd": "cancel_editing"}); return self\n'
      '    def commit_value(self, v):        self._chain.append({"cmd": "commit_value", "value": v}); return self\n'
      '    def add_row(self):                self._chain.append({"cmd": "add_row"}); return self\n'
      '    def toggle_checkbox(self):        self._chain.append({"cmd": "toggle_checkbox"}); return self\n'
      '    def beep(self):                   self._chain.append({"cmd": "beep"}); return self\n'
      '    def select(self, **kw):           self._chain.append(self._mkd("select", kw)); return self\n'
      '    def scroll_to(self, **kw):        self._chain.append(self._mkd("scroll_to", kw)); return self\n'
      '    def banner(self, message="", level="info"): self._chain.append({"cmd": "banner", "message": message, "level": level}); return self\n',
    );
    _execSilent(
      'def commit(): return _Cmd("commit")\n'
      'def move(**kw): return _Cmd("move", **kw)\n'
      'def initiate_editing(**kw): return _Cmd("initiate_editing", **kw)\n'
      'def cancel_editing(): return _Cmd("cancel_editing")\n'
      'def commit_value(v): return _Cmd("commit_value", value=v)\n'
      'def add_row(): return _Cmd("add_row")\n'
      'def toggle_checkbox(): return _Cmd("toggle_checkbox")\n'
      'def beep(): return _Cmd("beep")\n'
      'def select(**kw): return _Cmd("select", **kw)\n'
      'def scroll_to(**kw): return _Cmd("scroll_to", **kw)\n'
      'def banner(message="", level="info"): return _Cmd("banner", message=message, level=level)\n',
    );
    _cmdBootstrapped = true;
  }

  static void _bootstrapExecEval() {
    if (_execEvalBootstrapped) return;

    // Ensure _cfmt and _Cmd are available
    _bootstrapFmt();
    _bootstrapCmd();

    // Initialize the user preludes registry — bridges (chart, field, cell)
    // append themselves here so _epyx_exec_eval merges them into the
    // sandboxed eval namespace.
    _execSilent('_epyx_user_preludes = {}\n');

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
      '            "_Cmd": _Cmd,\n'
      '            "commit": commit, "move": move,\n'
      '            "initiate_editing": initiate_editing,\n'
      '            "cancel_editing": cancel_editing,\n'
      '            "commit_value": commit_value,\n'
      '            "add_row": add_row,\n'
      '            "toggle_checkbox": toggle_checkbox,\n'
      '            "beep": beep,\n'
      '            "select": select,\n'
      '            "scroll_to": scroll_to,\n'
      '            "banner": banner,\n'
      '        }\n'
      '        _g.update(_epyx_user_preludes)\n'
      '        # Wrap top-level dict ctx values via _DotDict (defined in\n'
      '        # the `the` prelude) so cross-doclet namespaces like\n'
      '        # `bigpush.tasks.Stage` work via attribute syntax. Plain\n'
      '        # values (lists, strings, etc.) pass through unchanged.\n'
      '        try:\n'
      '            _Wrap = _DotDict\n'
      '        except NameError:\n'
      '            _Wrap = None\n'
      '        for _k, _v in ctx.items():\n'
      '            if _Wrap is not None and isinstance(_v, dict):\n'
      '                _g[_k] = _Wrap(_v)\n'
      '            else:\n'
      '                _g[_k] = _v\n'
      '        # Use _g as BOTH globals and locals so any function defined\n'
      '        # by exec_code captures _g as its __globals__. project_render_funcs\n'
      '        # wraps render/on_key bodies as callables, and free names like\n'
      '        # `chart`/`field`/`cell` would otherwise raise NameError at call time.\n'
      '        if exec_code:\n'
      '            exec(exec_code, _g, _g)\n'
      '        if eval_code:\n'
      '            result = eval(eval_code, _g, _g)\n'
      '            if isinstance(result, _Cmd):\n'
      '                print(_json_dumps(result._chain))\n'
      '            else:\n'
      '                print(_json_dumps(result))\n'
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
      if (decoded is Map && decoded.containsKey('__error__')) {
        // Only emit error path to /tmp diag — happy path is hot, don't log.
        _diagExecEval('__error__: ${decoded['__error__']}');
        return null;
      }
      return decoded;
    } catch (e) {
      _diagExecEval('jsonDecode threw on output="${trimmed.substring(0, trimmed.length.clamp(0, 200))}"');
      return null;
    }
  }

  static void _diagExecEval(String msg) {
    final stamp = DateTime.now().toIso8601String();
    try {
      io.File('/tmp/einput_keys.log').writeAsStringSync(
        '[$stamp] [execEval] $msg\n',
        mode: io.FileMode.append,
        flush: true,
      );
    } catch (_) {
      // dart:io is sandboxed on web — fall back to print so the
      // line surfaces in the browser console.
      print('[$stamp] [execEval] $msg');
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
