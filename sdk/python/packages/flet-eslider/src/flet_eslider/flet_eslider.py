"""flet-eslider: custom slider control with focus + type-to-replace +
on_key projection scripting.

`EInputSlider` is a Flet LayoutControl that wraps a Flutter Slider with:

- A FocusNode (the slider receives keyboard focus and key events).
- A configurable focus border color (drawn around the whole widget).
- Type-to-replace: while focused, typing digits/sign/decimal switches
  the value-display label into an inline text input that accumulates
  the typed value; Enter commits, Esc cancels.
- Client-side `def on_key(key, modifiers, value, ...)` projection eval
  via the same MicroPython render-plane protocol that EInputText uses.

Application code should not instantiate this directly — `EScalar` (in
`epyx.controls.escalar`) substitutes EInputSlider for `ft.Slider` when
the α paradigm is enabled (`EPYX_USE_ALPHA=1`, default).
"""

from dataclasses import field
from typing import Optional

import flet as ft


@ft.control("flet_eslider_input")
class EInputSlider(ft.LayoutControl):
    """Custom Flutter Slider with spreadsheet-grade keyboard model.

    Properties are intentionally minimal — this is the substrate for
    the EScalar wrapper, which adds the property machinery on top.
    """

    # ─── Slider state ─────────────────────────────────────────────────────
    value: float = field(default=0.0, metadata={"data_field": "value"})
    min_value: float = field(default=0.0, metadata={"data_field": "min_value"})
    max_value: float = field(default=100.0, metadata={"data_field": "max_value"})
    divisions: Optional[int] = field(default=None,
                                       metadata={"data_field": "divisions"})

    # `display` is the text shown below the slider (formatted value
    # from spec_code / α `code`). When the user types-to-replace, the
    # display is temporarily replaced by the typed buffer.
    display: Optional[str] = field(default=None, metadata={"data_field": "display"})
    label: Optional[str] = field(default=None, metadata={"data_field": "label"})

    # ─── Style ────────────────────────────────────────────────────────────
    active_color: Optional[str] = field(default=None,
                                          metadata={"data_field": "active_color"})
    inactive_color: Optional[str] = field(default=None,
                                            metadata={"data_field": "inactive_color"})
    text_color: Optional[str] = field(default=None,
                                        metadata={"data_field": "text_color"})
    font_size: float = field(default=14.0, metadata={"data_field": "font_size"})

    # Focus border — drawn around the outer slider container when this
    # control has keyboard focus. Hidden when unfocused (or set color
    # to transparent to disable entirely).
    focus_border_color: str = field(default="#0066FF",
                                      metadata={"data_field": "focus_border_color"})
    focus_border_width: float = field(default=2.0,
                                        metadata={"data_field": "focus_border_width"})

    # ─── Numeric formatting ────────────────────────────────────────────────
    # 'int' or 'float' — affects type-to-replace parsing and the
    # default display formatter (int → no decimals, float → strip
    # trailing zeros).
    ptype: str = field(default="float", metadata={"data_field": "ptype"})

    # ─── Render plane integration ──────────────────────────────────────────
    # The control id (Flet UID as a string) of the host EScalar — the
    # Dart widget uses this to look up the on_key projection from
    # RenderPlaneControl. When empty, the widget uses only its built-in
    # baseline keyboard behavior (arrow keys step by step size).
    host_control_id: str = field(default="",
                                   metadata={"data_field": "host_control_id"})

    # ─── Events ───────────────────────────────────────────────────────────
    # Fired when the slider value changes (drag, arrow key, or commit
    # of a typed value). Event data: JSON {"value": float}.
    on_value_change: Optional[ft.ControlEventHandler["EInputSlider"]] = None

    # Fired when the user commits a typed value (Enter on the inline
    # text buffer) or types a value through commit-by-blur. Event
    # data: JSON {"value": float, "reason": "enter" | "blur" | "command"}.
    on_submit: Optional[ft.ControlEventHandler["EInputSlider"]] = None

    # Fired when on_key returns a `banner` command. Event data: JSON
    # {"message": str, "level": "info" | "warn" | "error"}.
    on_banner: Optional[ft.ControlEventHandler["EInputSlider"]] = None

    # Fired when focus state changes. Event data: JSON {"focused": bool}.
    on_focus_change: Optional[ft.ControlEventHandler["EInputSlider"]] = None

    # Fired when the user (or a render-plane command) cancels the
    # in-progress type-to-replace edit. Event data: JSON {}.
    on_cancel: Optional[ft.ControlEventHandler["EInputSlider"]] = None
