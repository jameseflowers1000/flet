/// MicroPython prelude that defines a minimal `the` namespace for α
/// on_key handlers. Used by EInputText to evaluate projections that
/// reference `the.key`, `the.keys.up`, `the.mods.cmd in the.modifiers`,
/// and the fluent text-edit chain (`the.replace(...).commit().select_all()`).
///
/// Must work in MicroPython (no dataclasses, no typing).
const String theBridgePrelude = '''
class _DotDict:
    """Wrap a nested dict so `obj.attr` works alongside `obj["key"]`.

    Enables α user code that references cross-doclet namespaces like
    `bigpush.tasks.Stage` on the render plane — the Python side
    serialises the ValueContainer tree to nested plain dicts, the
    `_epyx_exec_eval` bootstrap wraps top-level ctx dict-values via
    this class, and attribute access auto-recurses into nested dicts.
    """
    def __init__(self, data):
        self._data = data
    def __getattr__(self, name):
        d = self._data
        if isinstance(d, dict) and name in d:
            v = d[name]
            if isinstance(v, dict):
                return _DotDict(v)
            return v
        raise AttributeError(name)
    def __getitem__(self, key):
        v = self._data[key]
        if isinstance(v, dict):
            return _DotDict(v)
        return v
    def __contains__(self, key):
        return isinstance(self._data, dict) and key in self._data
    def __iter__(self):
        return iter(self._data)
    def __len__(self):
        return len(self._data) if hasattr(self._data, '__len__') else 0


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
    def __init__(self):
        # Pre-allocate every ETab cell ctx + EScalar field ctx attribute
        # the projection wrappers might assign. MicroPython silently drops
        # attribute writes on instances that don't have a pre-allocated
        # slot for that name (see feedback_micropython_setattr.md), so the
        # later read raises `'_Bag' object has no attribute X`. Listing
        # them here gives the slot.
        self.value = ""
        self.row = None
        self.row_index = 0
        self.col_index = 0
        self.col_name = ""
        self.is_selected = False
        self.is_hovered = False
        self.is_hovered_cell = False
        self.is_focused = False
        self.is_editing = False
        self.is_overridden = False
        self.editing = False  # legacy alias for is_editing
        self.hovered_col = -1
        self.total_rows = 0
        self.total_cols = 0
        self.viewport_pos = 0
        self.viewport_count = 0
        # EScalar field-ctx
        self.raw = ""
        self.min = None
        self.max = None
        self.ctype = ""
        self.cursor = 0
        self.selection = None
        self.selection_start = 0
        self.selection_end = 0

    # Field actions per schema (`the.field.replace`, `.clear`, `.commit`,
    # `.select_all`, `.cancel`). These forward into the master `the._commands`
    # stream so the Dart-side InputCommandExecutor picks them up the same
    # way it does for bare `the.replace(...)`. Schema canonicalises the
    # actions under `the.field`; bare `the.replace` is also accepted on the
    # master bridge for legacy snippets.
    def replace(self, text):
        the._commands.append({"cmd": "replace", "text": str(text)})
        return the
    def clear(self):
        the._commands.append({"cmd": "clear"})
        return the
    def commit(self):
        the._commands.append({"cmd": "commit"})
        return the
    def select_all(self):
        the._commands.append({"cmd": "select_all"})
        return the
    def cancel(self):
        the._commands.append({"cmd": "cancel"})
        return the
    def insert(self, text):
        the._commands.append({"cmd": "insert", "text": str(text)})
        return the

class The:
    def __init__(self):
        self.cell = _Bag()
        self.field = _Bag()
        self.keys = _Symbolic()
        self.mods = _Symbolic()
        self.modifiers = []
        self.key = ""
        self._commands = []

    def _reset_actions(self):
        self._commands = []

    # Every action returns `self` so chains compose uniformly:
    #     the.replace("x").commit().select_all()
    #     the.initiate_editing(prompt=...).banner("hint", level="info")
    # The Dart-side _executeCommandChain reads the accumulated
    # `the._commands` list and dispatches each {cmd, ...kwargs} entry.

    def clear(self):
        self._commands.append({"cmd": "clear"})
        return self

    def commit(self):
        self._commands.append({"cmd": "commit"})
        return self

    def replace(self, text):
        self._commands.append({"cmd": "replace", "text": str(text)})
        return self

    def insert(self, text):
        self._commands.append({"cmd": "insert", "text": str(text)})
        return self

    def select_all(self):
        self._commands.append({"cmd": "select_all"})
        return self

    def cancel(self):
        self._commands.append({"cmd": "cancel"})
        return self

    def beep(self):
        self._commands.append({"cmd": "beep"})
        return self

    def banner(self, message, level="info"):
        self._commands.append({"cmd": "banner",
                                "message": str(message), "level": str(level)})
        return self

    def move_to_next(self):
        self._commands.append({"cmd": "move_to_next"})
        return self

    def move_to_prev(self):
        self._commands.append({"cmd": "move_to_prev"})
        return self

    # ETab-flavoured actions
    def initiate_editing(self, **kw):
        d = {"cmd": "initiate_editing"}
        d.update(kw)
        self._commands.append(d)
        return self

    def cancel_editing(self, **kw):
        self._commands.append({"cmd": "cancel_editing"})
        return self

    def move(self, **kw):
        d = {"cmd": "move"}
        d.update(kw)
        self._commands.append(d)
        return self

    def commit_value(self, value, **kw):
        d = {"cmd": "commit_value", "value": value}
        d.update(kw)
        self._commands.append(d)
        return self

    def add_row(self, **kw):
        d = {"cmd": "add_row"}
        d.update(kw)
        self._commands.append(d)
        return self

    def toggle_checkbox(self, **kw):
        d = {"cmd": "toggle_checkbox"}
        d.update(kw)
        self._commands.append(d)
        return self

    def select(self, **kw):
        d = {"cmd": "select"}
        d.update(kw)
        self._commands.append(d)
        return self

    def scroll_to(self, **kw):
        d = {"cmd": "scroll_to"}
        d.update(kw)
        self._commands.append(d)
        return self

    def override(self, row, col):
        # Read-only accessor when wired by ETab; here on the render
        # plane it returns None — the per-statement try/except in
        # render projections swallows the resulting comparison.
        return None

the = The()
try:
    _epyx_user_preludes['the'] = the
except NameError:
    pass
''';
