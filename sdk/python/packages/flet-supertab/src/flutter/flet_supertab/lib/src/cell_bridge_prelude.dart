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
        self._size = None
        self._font = None
        self._weight = None
        self._italic = None
        self._tooltip = None
        self._icon = None
        self._display = None
        self._z = 0
        self._color_z = -1
        self._bg_z = -1
        self._size_z = -1
        self._font_z = -1
        self._weight_z = -1
        self._italic_z = -1
        self._tooltip_z = -1
        self._icon_z = -1
        self._display_z = -1

    def color(self, hex_or_name):
        self._color = str(hex_or_name) if hex_or_name is not None else None
        self._color_z = self._z

    def bg(self, hex_or_name):
        self._bg = str(hex_or_name) if hex_or_name is not None else None
        self._bg_z = self._z

    def display(self, text):
        self._display = str(text) if text is not None else None
        self._display_z = self._z
    def format(self, text):
        # legacy alias for display()
        self._display = str(text) if text is not None else None
        self._display_z = self._z

    def size(self, px):
        self._size = px
        self._size_z = self._z

    def font(self, family):
        self._font = str(family) if family is not None else None
        self._font_z = self._z

    def weight(self, name):
        self._weight = str(name) if name is not None else None
        self._weight_z = self._z

    def italic(self, flag=True):
        self._italic = bool(flag)
        self._italic_z = self._z

    def tooltip(self, text):
        self._tooltip = str(text) if text is not None else None
        self._tooltip_z = self._z

    def icon(self, name):
        self._icon = str(name) if name is not None else None
        self._icon_z = self._z

    def _to_config(self):
        config = {}
        if self._color is not None:
            config["color"] = self._color
            config["color_z"] = self._color_z
        if self._bg is not None:
            config["bg"] = self._bg
            config["bg_z"] = self._bg_z
        if self._size is not None:
            config["size"] = self._size
            config["size_z"] = self._size_z
        if self._font is not None:
            config["font"] = self._font
            config["font_z"] = self._font_z
        if self._weight is not None:
            config["weight"] = self._weight
            config["weight_z"] = self._weight_z
        if self._italic is not None:
            config["italic"] = self._italic
            config["italic_z"] = self._italic_z
        if self._tooltip is not None:
            config["tooltip"] = self._tooltip
            config["tooltip_z"] = self._tooltip_z
        if self._icon is not None: config["icon"] = self._icon
        if self._display is not None:
            config["display"] = self._display
            config["display_z"] = self._display_z
        return config

cell = CellBridge()
try:
    _epyx_user_preludes['cell'] = cell
except NameError:
    pass
''';
