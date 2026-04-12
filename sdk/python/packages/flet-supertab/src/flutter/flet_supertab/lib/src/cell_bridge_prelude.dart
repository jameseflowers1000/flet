/// MicroPython prelude that defines the CellBridge class and a singleton
/// instance `cell` in the global namespace. Registered with
/// MicroPythonService at flet-supertab extension load time.
///
/// ETab's spec_code uses this bridge inside def render() and def on_key()
/// to express per-cell presentation values:
///
///   def render(value, row, col_name, row_index, is_selected):
///       if value < 0:
///           cell.bg("#fee")
///           cell.color("#900")
///           cell.weight("bold")
///           cell.tooltip(f"Negative: {value}")
///
/// The bridge accumulates state via method calls and exposes _to_config()
/// to serialize to a dict. Call cell._reset() before each evaluation to
/// clear accumulated state from the previous cell.
///
/// Must work in MicroPython (no dataclasses, no typing).
const String cellBridgePrelude = '''
class CellBridge:
    def __init__(self):
        self._reset()

    def _reset(self):
        self._color = None
        self._bg = None
        self._format = None
        self._size = None
        self._font = None
        self._weight = None
        self._italic = None
        self._tooltip = None
        self._icon = None

    def color(self, hex_or_name):
        self._color = str(hex_or_name) if hex_or_name is not None else None

    def bg(self, hex_or_name):
        self._bg = str(hex_or_name) if hex_or_name is not None else None

    def format(self, text):
        self._format = str(text) if text is not None else None

    def size(self, px):
        self._size = px

    def font(self, family):
        self._font = str(family) if family is not None else None

    def weight(self, name):
        self._weight = str(name) if name is not None else None

    def italic(self, flag=True):
        self._italic = bool(flag)

    def tooltip(self, text):
        self._tooltip = str(text) if text is not None else None

    def icon(self, name):
        self._icon = str(name) if name is not None else None

    def _to_config(self):
        config = {}
        if self._color is not None: config["color"] = self._color
        if self._bg is not None: config["bg"] = self._bg
        if self._format is not None: config["format"] = self._format
        if self._size is not None: config["size"] = self._size
        if self._font is not None: config["font"] = self._font
        if self._weight is not None: config["weight"] = self._weight
        if self._italic is not None: config["italic"] = self._italic
        if self._tooltip is not None: config["tooltip"] = self._tooltip
        if self._icon is not None: config["icon"] = self._icon
        return config

cell = CellBridge()
try:
    _epyx_user_preludes['cell'] = cell
except NameError:
    pass
''';
