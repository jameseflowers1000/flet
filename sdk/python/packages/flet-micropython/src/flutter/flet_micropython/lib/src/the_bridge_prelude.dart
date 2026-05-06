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
    # __setattr__ — runtime hook for α `the.field.value = X` sugar.
    #
    # When user code writes `the.field.value = X`, this emits a
    # `set_value` command on the master `the._commands` list (the same
    # vocabulary the explicit `.set(X)` form uses). The Dart-side
    # widgets (EInputSlider / EInputText) intercept set_value and apply
    # the new value via the existing `_setValue(...)` path.
    #
    # Framework-side seeding (the wrapper assigning ctx → bridge) goes
    # through `_seed()` instead, which bypasses command emission so the
    # per-keypress ctx refresh doesn't spam set_value commands with
    # the *current* value at the start of every projection eval.
    #
    # Other attribute writes (`the.field.bg = '#fff'`, etc.) are NOT
    # routed through __setattr__ — those are still rewritten at α-compile
    # time by `_SetterToCallRewriter` in alpha/analyzer.py, dispatching
    # to existing bridge_setter methods (`bg`, `color`, `size`, …).
    # Only `value` has this runtime path; AST rewrite stays as
    # belt-and-suspenders for the rest.
    def __setattr__(self, name, value):
        if name == "value":
            the._commands.append({"cmd": "set_value", "value": value})
        object.__setattr__(self, name, value)

    def _seed(self, name, value):
        """Framework-side assignment that bypasses __setattr__'s command
        emission. Called by the projection wrapper to refresh ctx state
        each keypress without emitting spurious set_value commands."""
        object.__setattr__(self, name, value)

    def __init__(self):
        # Pre-allocate every ETab cell ctx + EScalar field ctx attribute
        # the projection wrappers might assign. Use object.__setattr__
        # directly so __init__ doesn't trigger the command-emitting path
        # above (which would also fail because `the` isn't fully built
        # at __init__ time on the very first instance).
        _set = object.__setattr__
        _set(self, "value", "")
        _set(self, "row", None)
        _set(self, "row_index", 0)
        _set(self, "col_index", 0)
        _set(self, "col_name", "")
        _set(self, "is_selected", False)
        _set(self, "is_hovered", False)
        _set(self, "is_hovered_cell", False)
        _set(self, "is_focused", False)
        _set(self, "is_editing", False)
        _set(self, "is_overridden", False)
        _set(self, "editing", False)  # legacy alias for is_editing
        _set(self, "hovered_col", -1)
        _set(self, "total_rows", 0)
        _set(self, "total_cols", 0)
        _set(self, "viewport_pos", 0)
        _set(self, "viewport_count", 0)
        # EScalar field-ctx
        _set(self, "raw", "")
        # `buffer` is the live text-controller content (text fields) or
        # the type-to-replace buffer (sliders). Distinct from `value`,
        # which is the *committed*, typed scalar value. Use buffer when
        # you need to inspect mid-edit state; use value otherwise.
        _set(self, "buffer", "")
        _set(self, "min", None)
        _set(self, "max", None)
        _set(self, "ctype", "")
        _set(self, "cursor", 0)
        _set(self, "selection", None)
        _set(self, "selection_start", 0)
        _set(self, "selection_end", 0)

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

    def set(self, value):
        # Slider-targeted setter: emits a `set_value` command that the
        # ESlider widget intercepts (text-field hosts ignore it). Lets
        # α on_key blocks set the slider directly:
        #     if the.key == the.keys.up:
        #         the.field.set(the.field.value + 1.0)
        the._commands.append({"cmd": "set_value", "value": float(value)})
        return the

    def edit(self, **kw):
        # Schema action: the.cell.edit(row=..., col_index=...). Routes
        # through the master `the._commands` so the Dart-side dispatcher
        # picks it up. The grid's command handler initiates editing on
        # the targeted (row, col_index) cell.
        d = {"cmd": "cell_edit"}
        d.update(kw)
        the._commands.append(d)
        return the

class The:
    # Master-owned attribute names — these are read/written on `the`
    # itself, never forwarded to a sub-bridge. Includes the sub-bridges,
    # event/key state, command list, and master action methods.
    _OWN_NAMES = ('cell', 'field', 'keys', 'mods', 'modifiers', 'key',
                   '_commands', '_primary', '_version')

    def __setattr__(self, name, value):
        # Internal/dunder names go straight to self.
        if name.startswith('_') or name in The._OWN_NAMES:
            object.__setattr__(self, name, value)
            return
        # Forward bare-attribute writes (the.value = X, the.color = X) to
        # the primary sub-bridge. EScalar/EInputText/ESlider contexts
        # default to `the.field`; ETab contexts can re-point _primary.
        primary = self.__dict__.get("_primary")
        if primary is not None:
            setattr(primary, name, value)
            return
        object.__setattr__(self, name, value)

    def __getattr__(self, name):
        # Only fires when normal lookup misses. Look up on the primary
        # sub-bridge so `the.value`, `the.buffer`, `the.is_editing` etc.
        # read through transparently.
        if name.startswith('_') or name in The._OWN_NAMES:
            raise AttributeError(name)
        primary = self.__dict__.get("_primary")
        if primary is not None:
            try:
                return getattr(primary, name)
            except AttributeError:
                pass
        raise AttributeError(name)

    def __init__(self):
        _set = object.__setattr__
        _set(self, "cell", _Bag())
        _set(self, "field", _Bag())
        _set(self, "keys", _Symbolic())
        _set(self, "mods", _Symbolic())
        _set(self, "modifiers", [])
        _set(self, "key", "")
        _set(self, "_commands", [])
        # Primary sub-bridge — defaults to `field` (EScalar/EInputText/
        # ESlider, the most common host). Cell-context handlers (ETab)
        # can point this to `cell` via `the._primary = the.cell`.
        _set(self, "_primary", self.field)

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
# Version sentinel — bumped whenever the prelude's surface changes
# (new methods, new __setattr__ semantics, etc.). User code can read
# `the._version` to confirm which prelude generation is loaded; tests
# can assert the expected version. Bump on every change to this file.
the._version = "alpha-collapse-v2"
try:
    _epyx_user_preludes['the'] = the
except NameError:
    pass
''';
