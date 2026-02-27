"""
MicroPythonEval - Client-side Python evaluation control.

Sends code + context to the Dart MicroPythonEvalControl, which evaluates
client-side via MicroPython WASM — no server round-trip.

Phase 1: Web only (WASM in browser).
Phase 2: Desktop/mobile via dart:ffi + embedded MicroPython C library.
"""

import json
from typing import Optional

import flet as ft


@ft.control("flet_micropython_eval")
class MicroPythonEval(ft.LayoutControl):
    """Client-side Python evaluation via MicroPython.

    Properties sent to Dart:
        code: Python expression to evaluate
        context: JSON-encoded context dict (available as `ctx` in code)

    Properties received from Dart:
        result: JSON-encoded evaluation result

    Events:
        on_result: fired when evaluation completes (result JSON in event data)
    """

    # Python expression to evaluate on the client
    code: Optional[str] = None

    # JSON-encoded context dict (available as `ctx` in the expression)
    context: Optional[str] = None

    # JSON-encoded result (set by Dart after evaluation)
    result: Optional[str] = None

    # Event handler: fired when evaluation completes
    on_result: Optional[ft.ControlEventHandler["MicroPythonEval"]] = None

    def evaluate(self, code: str, context: Optional[dict] = None):
        """Evaluate a Python expression on the client.

        Args:
            code: Python expression (has access to `ctx` dict and builtins)
            context: Optional dict passed as `ctx` to the expression
        """
        self.code = code
        self.context = json.dumps(context or {})
        self.update()

    def get_result(self):
        """Parse and return the last evaluation result.

        Returns the decoded JSON result, or None if no result yet.
        Raises ValueError if the result contains an error.
        """
        if not self.result:
            return None
        parsed = json.loads(self.result)
        if isinstance(parsed, dict) and '__error__' in parsed:
            raise ValueError(parsed['__error__'])
        return parsed
