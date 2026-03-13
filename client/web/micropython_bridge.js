/**
 * MicroPython WASM Bridge for Epyx Smart Templates
 *
 * Loads MicroPython WebAssembly runtime and exposes window._epyxMicroPython
 * namespace for Dart interop via dart:js_interop.
 *
 * Key insight: MicroPython's runPython() is like exec() — it does NOT return
 * expression values. We capture results via stdout (print → callback).
 *
 * API:
 *   _epyxMicroPython.init()               — async, ensure WASM loaded
 *   _epyxMicroPython.eval(code, ctxJson)  — sync, returns JSON string result
 *   _epyxMicroPython.fmt(code, ctxJson)   — sync, eval with ctx unpacked as top-level vars
 *   _epyxMicroPython.exec(code)           — sync, execute statements
 *   _epyxMicroPython.ready                — boolean getter
 *   _epyxMicroPython.getError()           — last error string
 */
(function () {
  var mp = null;       // MicroPython runtime instance
  var ready = false;
  var lastError = '';
  var initPromise = null;
  var capturedOutput = '';

  async function doInit() {
    if (mp) return;
    try {
      // Dynamic import of the ES module (vendored alongside this script)
      var mod = await import('./micropython/micropython.mjs');
      mp = await mod.loadMicroPython({
        url: './micropython/micropython.wasm',
        stdout: function (text) { capturedOutput += text; },
        stderr: function (text) { console.warn('[MicroPython stderr]', text); }
      });

      // Pre-load the eval helper into MicroPython.
      // It print()s the JSON result so we can capture it via stdout.
      mp.runPython(
        'import json\n' +
        '\n' +
        'def _epyx_eval(code, ctx_json):\n' +
        '    try:\n' +
        '        ctx = json.loads(ctx_json) if ctx_json else {}\n' +
        '        _g = {\n' +
        '            "ctx": ctx,\n' +
        '            "len": len,\n' +
        '            "sum": sum,\n' +
        '            "min": min,\n' +
        '            "max": max,\n' +
        '            "abs": abs,\n' +
        '            "round": round,\n' +
        '            "int": int,\n' +
        '            "float": float,\n' +
        '            "str": str,\n' +
        '            "bool": bool,\n' +
        '            "list": list,\n' +
        '            "dict": dict,\n' +
        '            "tuple": tuple,\n' +
        '            "range": range,\n' +
        '            "sorted": sorted,\n' +
        '            "reversed": reversed,\n' +
        '            "enumerate": enumerate,\n' +
        '            "zip": zip,\n' +
        '            "map": map,\n' +
        '            "filter": filter,\n' +
        '            "any": any,\n' +
        '            "all": all,\n' +
        '            "isinstance": isinstance,\n' +
        '            "type": type,\n' +
        '            "True": True,\n' +
        '            "False": False,\n' +
        '            "None": None,\n' +
        '        }\n' +
        '        result = eval(code, {"__builtins__": _g}, _g)\n' +
        '        print(json.dumps(result))\n' +
        '    except Exception as e:\n' +
        '        print(json.dumps({"__error__": str(e)}))\n'
      );

      // Pre-load helpers for fmt — comma formatting + eval with unpacked context.
      mp.runPython(
        'def _cfmt(value, decimals=2):\n' +
        '    """Format a number with comma thousands separator."""\n' +
        '    neg = value < 0\n' +
        '    value = abs(value)\n' +
        '    if decimals > 0:\n' +
        '        s = str(round(value * (10 ** decimals))) \n' +
        '        while len(s) <= decimals:\n' +
        '            s = "0" + s\n' +
        '        int_part = s[:-decimals]\n' +
        '        dec_part = s[-decimals:]\n' +
        '    else:\n' +
        '        int_part = str(round(value))\n' +
        '        dec_part = ""\n' +
        '    groups = []\n' +
        '    while int_part:\n' +
        '        groups.append(int_part[-3:])\n' +
        '        int_part = int_part[:-3]\n' +
        '    result = ",".join(reversed(groups)) if groups else "0"\n' +
        '    if dec_part:\n' +
        '        result += "." + dec_part\n' +
        '    return ("-" if neg else "") + result\n'
      );

      // Pre-load the fmt helper — like _epyx_eval but unpacks context
      // values as top-level names (so f"{y:.2f}" works, not f"{ctx['y']:.2f}").
      // Also exposes cfmt() for comma formatting (MicroPython lacks :, support).
      // Comma format specs (:,.Nf) are rewritten to cfmt() calls by Dart before
      // reaching here, so _epyx_fmt itself doesn't need regex.
      mp.runPython(
        'def _epyx_fmt(code, ctx_json):\n' +
        '    try:\n' +
        '        ctx = json.loads(ctx_json) if ctx_json else {}\n' +
        '        _g = {\n' +
        '            "cfmt": _cfmt,\n' +
        '            "len": len,\n' +
        '            "sum": sum,\n' +
        '            "min": min,\n' +
        '            "max": max,\n' +
        '            "abs": abs,\n' +
        '            "round": round,\n' +
        '            "int": int,\n' +
        '            "float": float,\n' +
        '            "str": str,\n' +
        '            "bool": bool,\n' +
        '            "list": list,\n' +
        '            "dict": dict,\n' +
        '            "tuple": tuple,\n' +
        '            "range": range,\n' +
        '            "sorted": sorted,\n' +
        '            "reversed": reversed,\n' +
        '            "enumerate": enumerate,\n' +
        '            "zip": zip,\n' +
        '            "map": map,\n' +
        '            "filter": filter,\n' +
        '            "any": any,\n' +
        '            "all": all,\n' +
        '            "isinstance": isinstance,\n' +
        '            "type": type,\n' +
        '            "True": True,\n' +
        '            "False": False,\n' +
        '            "None": None,\n' +
        '        }\n' +
        '        _g.update(ctx)\n' +
        '        result = eval(code, {"__builtins__": _g}, _g)\n' +
        '        print(json.dumps(result))\n' +
        '    except Exception as e:\n' +
        '        print(json.dumps({"__error__": str(e)}))\n'
      );

      // Pre-load the exec+eval helper — two-phase evaluation for render plane.
      // exec_code runs first (multi-statement body), then eval_code evaluates
      // the final expression and returns via print(json.dumps(result)).
      // Context is unpacked as top-level variables (like _epyx_fmt).
      mp.runPython(
        'def _epyx_exec_eval(exec_code, eval_code, ctx_json):\n' +
        '    try:\n' +
        '        ctx = json.loads(ctx_json) if ctx_json else {}\n' +
        '        _g = {\n' +
        '            "json": json,\n' +
        '            "__import__": __import__,\n' +
        '            "cfmt": _cfmt,\n' +
        '            "len": len,\n' +
        '            "sum": sum,\n' +
        '            "min": min,\n' +
        '            "max": max,\n' +
        '            "abs": abs,\n' +
        '            "round": round,\n' +
        '            "int": int,\n' +
        '            "float": float,\n' +
        '            "str": str,\n' +
        '            "bool": bool,\n' +
        '            "list": list,\n' +
        '            "dict": dict,\n' +
        '            "tuple": tuple,\n' +
        '            "range": range,\n' +
        '            "sorted": sorted,\n' +
        '            "reversed": reversed,\n' +
        '            "enumerate": enumerate,\n' +
        '            "zip": zip,\n' +
        '            "map": map,\n' +
        '            "filter": filter,\n' +
        '            "any": any,\n' +
        '            "all": all,\n' +
        '            "isinstance": isinstance,\n' +
        '            "type": type,\n' +
        '            "True": True,\n' +
        '            "False": False,\n' +
        '            "None": None,\n' +
        '        }\n' +
        '        _g.update(ctx)\n' +
        '        if exec_code:\n' +
        '            exec(exec_code, {"__builtins__": _g}, _g)\n' +
        '        if eval_code:\n' +
        '            result = eval(eval_code, {"__builtins__": _g}, _g)\n' +
        '            print(json.dumps(result))\n' +
        '        else:\n' +
        '            print(json.dumps(None))\n' +
        '    except Exception as e:\n' +
        '        print(json.dumps({"__error__": str(e)}))\n'
      );

      ready = true;
      lastError = '';
      console.log('[MicroPython] WASM runtime loaded');
    } catch (e) {
      lastError = String(e);
      console.error('[MicroPython] Failed to load:', e);
      throw e;
    }
  }

  window._epyxMicroPython = {
    init: function () {
      if (!initPromise) {
        initPromise = doInit();
      }
      return initPromise;
    },

    get ready() {
      return ready;
    },

    eval: function (code, contextJson) {
      if (!ready) {
        lastError = 'MicroPython not initialized';
        return '{"__error__": "MicroPython not initialized"}';
      }
      try {
        // Clear stdout buffer, run eval (prints JSON), read buffer
        capturedOutput = '';
        var callCode = '_epyx_eval(' +
          JSON.stringify(String(code)) + ', ' +
          JSON.stringify(String(contextJson || '{}')) + ')';
        mp.runPython(callCode);
        var result = capturedOutput.trim();
        lastError = '';
        return result || '{"__error__": "no output from eval"}';
      } catch (e) {
        lastError = String(e);
        return JSON.stringify({ '__error__': String(e) });
      }
    },

    fmt: function (code, contextJson) {
      if (!ready) {
        lastError = 'MicroPython not initialized';
        console.warn('[MicroPython fmt] not ready');
        return '{"__error__": "MicroPython not initialized"}';
      }
      try {
        capturedOutput = '';
        var callCode = '_epyx_fmt(' +
          JSON.stringify(String(code)) + ', ' +
          JSON.stringify(String(contextJson || '{}')) + ')';
        mp.runPython(callCode);
        var result = capturedOutput.trim();
        lastError = '';
        return result || '{"__error__": "no output from fmt"}';
      } catch (e) {
        lastError = String(e);
        console.error('[MicroPython fmt] error:', e);
        return JSON.stringify({ '__error__': String(e) });
      }
    },

    execEval: function (execBody, evalExpr, contextJson) {
      if (!ready) {
        lastError = 'MicroPython not initialized';
        return '{"__error__": "MicroPython not initialized"}';
      }
      try {
        capturedOutput = '';
        var callCode = '_epyx_exec_eval(' +
          JSON.stringify(String(execBody || '')) + ', ' +
          JSON.stringify(String(evalExpr || '')) + ', ' +
          JSON.stringify(String(contextJson || '{}')) + ')';
        mp.runPython(callCode);
        var result = capturedOutput.trim();
        if (result && result.indexOf('__error__') >= 0) {
          console.error('[MicroPython execEval] error:', result);
          lastError = result;
        } else {
          lastError = '';
        }
        return result || '{"__error__": "no output from execEval"}';
      } catch (e) {
        lastError = String(e);
        return JSON.stringify({ '__error__': String(e) });
      }
    },

    exec: function (code) {
      if (!ready) {
        lastError = 'MicroPython not initialized';
        return;
      }
      try {
        mp.runPython(String(code));
        lastError = '';
      } catch (e) {
        lastError = String(e);
        console.error('[MicroPython] exec error:', e);
      }
    },

    getError: function () {
      return lastError;
    }
  };

  // Auto-initialize on page load
  window._epyxMicroPython.init().catch(function (e) {
    console.warn('[MicroPython] Auto-init failed (will retry on first use):', e.message || e);
    initPromise = null;  // Allow retry
  });
})();
