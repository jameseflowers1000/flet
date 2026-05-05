# flet-eslider

Custom Flet slider control with first-class keyboard handling.

Drop-in replacement for `ft.Slider` when α is enabled. Adds:

- **Focus capture** — visible focus border (configurable color).
- **Built-in arrow keys** — Left/Right and Up/Down step the value by
  the slider's natural increment (or by `(max-min)/divisions` when set).
  Shift × arrow steps 10×. Home/End jump to min/max.
- **Type-to-replace** — when the slider has focus and the user types a
  digit, sign, or decimal point, the slider switches to an inline text
  buffer. Continue typing to accumulate. Enter commits, Esc cancels.
- **α `if the.key == ...:` blocks** — the slider's α `code` (on the
  hosting EScalar with `ctype: ESlider`) is parsed for top-level
  `if the.key == X:` statements; those run client-side via the
  flet-micropython render plane on each keystroke, with `the.field.value`
  populated from the slider's current value. Returned commands route
  through the shared command executor.
- **Same command vocabulary** as `flet-einput`'s `EInputText`:
  `commit / cancel / replace / insert / clear / select_all /
   move_to_next / move_to_prev / banner / beep`.

Companion to `flet-einput`. Both extensions share `flet_micropython`
for client-side keystroke evaluation. (The legacy spec_code form
`def on_key(...): return [...]` is NOT what runs here — α uses
inline `if the.key == ...:` blocks instead.)
