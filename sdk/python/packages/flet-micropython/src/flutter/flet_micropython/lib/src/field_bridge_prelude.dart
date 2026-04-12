/// MicroPython prelude that defines the FieldBridge class and a singleton
/// instance `field` in the global namespace. Registered with
/// MicroPythonService at extension load time.
///
/// EScalar's spec_code uses this bridge inside def render() to express
/// presentation values (display text, color, size, etc.) as imperative
/// API calls instead of returning a dict literal:
///
///   def render(value):
///       field.display(f"${value:,.2f}")
///       field.color("red" if value < 0 else "green")
///       field.size(18 if value > 100000 else 14)
///
/// The bridge accumulates state via method calls and exposes _to_config()
/// to serialize the accumulated state to a dict. Call field._reset() before
/// each evaluation to clear accumulated state from the previous run.
///
/// Must work in MicroPython (no dataclasses, no typing).
const String fieldBridgePrelude = '''
class FieldBridge:
    def __init__(self):
        self._reset()

    def _reset(self):
        self._display = None
        self._label = None
        self._color = None
        self._bg = None
        self._size = None
        self._font = None
        self._weight = None
        self._italic = None
        self._underline = None

    def display(self, text):
        self._display = str(text) if text is not None else None

    def label(self, text):
        self._label = str(text) if text is not None else None

    def color(self, hex_or_name):
        self._color = str(hex_or_name) if hex_or_name is not None else None

    def bg(self, hex_or_name):
        self._bg = str(hex_or_name) if hex_or_name is not None else None

    def size(self, px):
        self._size = px

    def font(self, family):
        self._font = str(family) if family is not None else None

    def weight(self, name):
        self._weight = str(name) if name is not None else None

    def italic(self, flag=True):
        self._italic = bool(flag)

    def underline(self, flag=True):
        self._underline = bool(flag)

    def _to_config(self):
        config = {}
        if self._display is not None: config["display"] = self._display
        if self._label is not None: config["label"] = self._label
        if self._color is not None: config["color"] = self._color
        if self._bg is not None: config["bg"] = self._bg
        if self._size is not None: config["size"] = self._size
        if self._font is not None: config["font"] = self._font
        if self._weight is not None: config["weight"] = self._weight
        if self._italic is not None: config["italic"] = self._italic
        if self._underline is not None: config["underline"] = self._underline
        return config

field = FieldBridge()
try:
    _epyx_user_preludes['field'] = field
except NameError:
    pass
''';
