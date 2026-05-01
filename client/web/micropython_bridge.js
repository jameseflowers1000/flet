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
        heapsize: 2097152,  // 2 MB (default was 1 MB)
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
        '            "type": type, "set": set,\n' +
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

      // _epyx_user_preludes — registry for user-defined bridges (chart,
      // field, cell, ...) that get merged into the sandboxed eval namespace.
      // Each prelude script appends its bridge instance to this dict so
      // _epyx_exec_eval and _epyx_fmt can expose them to user code.
      mp.runPython('_epyx_user_preludes = {}\n');

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
        '            "type": type, "set": set,\n' +
        '            "True": True,\n' +
        '            "False": False,\n' +
        '            "None": None,\n' +
        '        }\n' +
        '        _g.update(_epyx_user_preludes)\n' +
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
        '            "type": type, "set": set,\n' +
        '            "True": True,\n' +
        '            "False": False,\n' +
        '            "None": None,\n' +
        '            "_Cmd": _Cmd,\n' +
        '            "commit": commit,\n' +
        '            "move": move,\n' +
        '            "initiate_editing": initiate_editing,\n' +
        '            "cancel_editing": cancel_editing,\n' +
        '            "commit_value": commit_value,\n' +
        '            "add_row": add_row,\n' +
        '            "toggle_checkbox": toggle_checkbox,\n' +
        '            "beep": beep,\n' +
        '            "select": select,\n' +
        '            "scroll_to": scroll_to,\n' +
        '            "banner": banner,\n' +
        '        }\n' +
        '        _g.update(_epyx_user_preludes)\n' +
        '        # Wrap top-level dict ctx values via _DotDict (defined in\n' +
        '        # the `the` prelude) so cross-doclet namespaces like\n' +
        '        # `bigpush.tasks.Stage` work via attribute syntax. Plain\n' +
        '        # values pass through unchanged.\n' +
        '        try:\n' +
        '            _Wrap = _DotDict\n' +
        '        except NameError:\n' +
        '            _Wrap = None\n' +
        '        for _k, _v in ctx.items():\n' +
        '            if _Wrap is not None and isinstance(_v, dict):\n' +
        '                _g[_k] = _Wrap(_v)\n' +
        '            else:\n' +
        '                _g[_k] = _v\n' +
        '        # Use _g as BOTH globals and locals so any function defined\n' +
        '        # by exec_code captures _g as its __globals__. Otherwise the\n' +
        '        # function would only see {"__builtins__": ...} at call time\n' +
        '        # and free names like `chart`/`field`/`cell` (the bridge\n' +
        '        # singletons) would raise NameError. project_render_funcs\n' +
        '        # wraps every render/on_key body as a callable, so this matters.\n' +
        '        if exec_code:\n' +
        '            exec(exec_code, _g, _g)\n' +
        '        if eval_code:\n' +
        '            result = eval(eval_code, _g, _g)\n' +
        '            if isinstance(result, _Cmd):\n' +
        '                print(json.dumps(result._chain))\n' +
        '            else:\n' +
        '                print(json.dumps(result))\n' +
        '        else:\n' +
        '            print(json.dumps(None))\n' +
        '    except Exception as e:\n' +
        '        print(json.dumps({"__error__": str(e)}))\n'
      );

      // on_key_code command builder (§6): chainable command API
      // _Cmd builds a list of command dicts. Factory functions create initial commands.
      // Result is serialized as JSON list: [{"cmd":"commit"}, {"cmd":"move","row":1}]
      mp.runPython(
        'class _Cmd:\n' +
        '    def _mkd(self, cmd, kw):\n' +
        '        d = {"cmd": cmd}\n' +
        '        d.update(kw)\n' +
        '        return d\n' +
        '    def __init__(self, cmd, **kw):\n' +
        '        self._chain = [self._mkd(cmd, kw)]\n' +
        '    def move(self, **kw):             self._chain.append(self._mkd("move", kw)); return self\n' +
        '    def commit(self):                 self._chain.append({"cmd": "commit"}); return self\n' +
        '    def initiate_editing(self, **kw): self._chain.append(self._mkd("initiate_editing", kw)); return self\n' +
        '    def cancel_editing(self):         self._chain.append({"cmd": "cancel_editing"}); return self\n' +
        '    def commit_value(self, v):        self._chain.append({"cmd": "commit_value", "value": v}); return self\n' +
        '    def add_row(self):                self._chain.append({"cmd": "add_row"}); return self\n' +
        '    def toggle_checkbox(self):        self._chain.append({"cmd": "toggle_checkbox"}); return self\n' +
        '    def beep(self):                   self._chain.append({"cmd": "beep"}); return self\n' +
        '    def select(self, **kw):           self._chain.append(self._mkd("select", kw)); return self\n' +
        '    def scroll_to(self, **kw):        self._chain.append(self._mkd("scroll_to", kw)); return self\n' +
        '    def banner(self, message="", level="info"): self._chain.append({"cmd": "banner", "message": message, "level": level}); return self\n' +
        'def commit(): return _Cmd("commit")\n' +
        'def move(**kw): return _Cmd("move", **kw)\n' +
        'def initiate_editing(**kw): return _Cmd("initiate_editing", **kw)\n' +
        'def cancel_editing(): return _Cmd("cancel_editing")\n' +
        'def commit_value(v): return _Cmd("commit_value", value=v)\n' +
        'def add_row(): return _Cmd("add_row")\n' +
        'def toggle_checkbox(): return _Cmd("toggle_checkbox")\n' +
        'def beep(): return _Cmd("beep")\n' +
        'def select(**kw): return _Cmd("select", **kw)\n' +
        'def scroll_to(**kw): return _Cmd("scroll_to", **kw)\n' +
        'def banner(message="", level="info"): return _Cmd("banner", message=message, level=level)\n'
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
