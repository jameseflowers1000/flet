"""flet-einput: custom input controls with on_key_code scripting.

EInputText is a Flet LayoutControl that wraps a Flutter TextField with:
- Spreadsheet-style focus (select-all on focus, type-to-replace, no caret
  bounce on display updates).
- Client-side on_key_code via the render plane: define `def on_key(...)` in
  the host EScalar's spec_code, the Dart widget reads the projection from
  RenderPlaneControl and evaluates per keystroke via MicroPython.

This control is used internally by epyx's ETextField wrapper. Application
code should not instantiate it directly — use ETextField.
"""

from dataclasses import field
from typing import Optional

import flet as ft


@ft.control("flet_einput_text")
class EInputText(ft.LayoutControl):
    """Custom Flutter TextField with spreadsheet focus model and on_key scripting.

    Properties are intentionally minimal — this is the substrate for ETextField,
    which adds the EScalar property machinery on top. Style is flat (no
    TextStyle object) so it serializes cleanly to Dart via Flet's data_field
    metadata.

    Keyboard scripting: the `host_control_id` property tells the Dart widget
    which RenderPlane projection key to read for `on_key`. EScalar's
    _refresh_spec sets this to the EScalar control's id when projecting.
    """

    # ─── Text content ─────────────────────────────────────────────────────
    # `value` is the RAW editable string — what the user actually types and
    # what gets shown while the field is focused. `display` is the FORMATTED
    # presentation string from spec_code (e.g. "4.50% per year") — shown
    # when the field is NOT focused. The Dart widget swaps between them
    # on focus/blur so the user always edits the raw value but sees the
    # formatted display when idle.
    value: str = field(default="", metadata={"data_field": "value"})
    display: Optional[str] = field(default=None, metadata={"data_field": "display"})
    label: Optional[str] = field(default=None, metadata={"data_field": "label"})
    hint_text: Optional[str] = field(default=None, metadata={"data_field": "hint_text"})

    # ─── Behavior ─────────────────────────────────────────────────────────
    read_only: bool = field(default=False, metadata={"data_field": "read_only"})
    multiline: bool = field(default=False, metadata={"data_field": "multiline"})
    min_lines: int = field(default=1, metadata={"data_field": "min_lines"})
    max_lines: int = field(default=1, metadata={"data_field": "max_lines"})
    select_all_on_focus: bool = field(default=True, metadata={"data_field": "select_all_on_focus"})

    # ─── Style (flat — no TextStyle object) ───────────────────────────────
    text_color: Optional[str] = field(default=None, metadata={"data_field": "text_color"})
    bg_color: Optional[str] = field(default=None, metadata={"data_field": "bg_color"})
    border_color: Optional[str] = field(default=None, metadata={"data_field": "border_color"})
    focused_border_color: Optional[str] = field(default=None, metadata={"data_field": "focused_border_color"})
    border_width: float = field(default=2.0, metadata={"data_field": "border_width"})
    font_size: float = field(default=14.0, metadata={"data_field": "font_size"})
    font_family: Optional[str] = field(default=None, metadata={"data_field": "font_family"})
    font_weight: Optional[str] = field(default=None, metadata={"data_field": "font_weight"})
    italic: bool = field(default=False, metadata={"data_field": "italic"})
    underline: bool = field(default=False, metadata={"data_field": "underline"})

    # ─── Render plane integration ─────────────────────────────────────────
    # The control id (Flet UID as a string) of the host EScalar — the Dart
    # widget uses this to look up the on_key projection from RenderPlaneControl.
    # When empty, the Dart widget falls back to its hardcoded baseline only.
    host_control_id: str = field(default="", metadata={"data_field": "host_control_id"})

    # ─── Typed value bridge (α `the.field.value`) ─────────────────────────
    # `host_value` is the *committed* scalar value, kept in sync with the
    # server-side EScalar. The on_key ctx seeds `the.field.value` from
    # this — already typed per `ptype` — so user code never has to
    # `float(...)` and never reads a half-typed buffer like "1.5e".
    # `the.field.buffer` exposes the raw text controller content for
    # snippets that genuinely care about mid-edit state.
    host_value: str = field(default="", metadata={"data_field": "host_value"})

    # `'int' | 'float' | 'str'` — drives the host_value parse on the
    # Dart side. Default 'str' = bypass; behaves as before.
    ptype: str = field(default="str", metadata={"data_field": "ptype"})

    # ─── Events ───────────────────────────────────────────────────────────
    # Fired on every keystroke (after the Dart widget has updated its
    # internal text). Event data: JSON {"value": str}
    on_value_change: Optional[ft.ControlEventHandler["EInputText"]] = None

    # Fired when the user commits (Enter, blur, or on_key `commit` command).
    # Event data: JSON {"value": str, "reason": "enter" | "blur" | "command"}
    on_submit: Optional[ft.ControlEventHandler["EInputText"]] = None

    # Fired when on_key returns a `banner` command. Event data: JSON
    # {"message": str, "level": "info" | "warn" | "error"}
    on_banner: Optional[ft.ControlEventHandler["EInputText"]] = None

    # Fired when focus state changes. Event data: JSON {"focused": bool}
    on_focus_change: Optional[ft.ControlEventHandler["EInputText"]] = None

    # Fired when the user (or a render-plane command) cancels the edit.
    # Event data: JSON {} (no payload — cancel is identity-only).
    on_cancel: Optional[ft.ControlEventHandler["EInputText"]] = None
