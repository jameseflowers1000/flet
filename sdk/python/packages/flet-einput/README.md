# flet-einput

Custom Flet input controls (`EInputText`, `EInputSlider`) wrapping Flutter
TextField/Slider with:

- Spreadsheet-grade focus model (select-all on focus, type-to-replace, no
  caret bounce on display updates).
- Client-side `on_key_code` scripting via the canonical render plane: define
  `def on_key(key, modifiers, value, cursor, selection)` in the host control's
  `spec_code`, return a list of command dicts, executed locally in Dart by
  MicroPython without a Python round-trip.

Companion to `epyx`'s EScalar — used internally by `ETextField` and `ESlider`
to replace their default `ft.TextField` / `ft.Slider` inner widgets.
