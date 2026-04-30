/// MicroPython prelude that defines a minimal `the` namespace for α
/// on_key handlers. Used by EInputText to evaluate projections that
/// reference `the.key`, `the.keys.up`, `the.mods.cmd in the.modifiers`,
/// and the fluent text-edit chain (`the.replace(...).commit().select_all()`).
///
/// Must work in MicroPython (no dataclasses, no typing).
const String theBridgePrelude = '''
class _Symbolic:
    # Map common α key names → Dart-side _logicalKeyName output.
    # For unmapped names, return the attribute name itself (so letters
    # `the.keys.k → "k"` still work).
    _MAP = {
        "up": "Arrow_Up", "down": "Arrow_Down",
        "left": "Arrow_Left", "right": "Arrow_Right",
        "enter": "Enter", "tab": "Tab", "escape": "Escape",
        "delete": "Delete", "backspace": "Backspace",
        "space": "Space", "home": "Home", "end": "End",
        "page_up": "Page_Up", "page_down": "Page_Down",
        "f2": "F2",
    }
    def __getattr__(self, name):
        return _Symbolic._MAP.get(name, name)

class _Bag:
    pass

class _Chain:
    def __init__(self, the_ref):
        self._the = the_ref
    def commit(self, *a, **k):
        self._the._commands.append({"cmd": "commit"})
        return self
    def select_all(self, *a, **k):
        self._the._commands.append({"cmd": "select_all"})
        return self
    def cancel(self, *a, **k):
        self._the._commands.append({"cmd": "cancel"})
        return self
    def beep(self, *a, **k):
        self._the._commands.append({"cmd": "beep"})
        return self

class The:
    def __init__(self):
        self.cell = _Bag()
        self.field = _Bag()
        self.cell.value = ""
        self.field.value = ""
        self.keys = _Symbolic()
        self.mods = _Symbolic()
        self.modifiers = set()
        self.key = ""
        self._commands = []
        self._chain = _Chain(self)

    def _reset_actions(self):
        self._commands = []

    # Fluent text-edit actions — return a chain stub so user code can
    # call .commit() / .select_all() etc. after them.
    def clear(self):
        self._commands.append({"cmd": "clear"})
        return self._chain

    def commit(self):
        self._commands.append({"cmd": "commit"})
        return self._chain

    def replace(self, text):
        self._commands.append({"cmd": "replace", "text": str(text)})
        return self._chain

    def insert(self, text):
        self._commands.append({"cmd": "insert", "text": str(text)})
        return self._chain

    def select_all(self):
        self._commands.append({"cmd": "select_all"})
        return self._chain

    def cancel(self):
        self._commands.append({"cmd": "cancel"})
        return self._chain

    def beep(self):
        self._commands.append({"cmd": "beep"})
        return self._chain

    def banner(self, message, level="info"):
        self._commands.append({"cmd": "banner",
                                "message": str(message), "level": str(level)})
        return self._chain

    def move_to_next(self):
        self._commands.append({"cmd": "move_to_next"})
        return self._chain

    def move_to_prev(self):
        self._commands.append({"cmd": "move_to_prev"})
        return self._chain

the = The()
try:
    _epyx_user_preludes['the'] = the
except NameError:
    pass
''';
