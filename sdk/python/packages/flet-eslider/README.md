# flet-eslider

Custom Flet slider control with first-class keyboard handling.

Drop-in replacement for `ft.Slider` when α is enabled. Adds:

- **Focus capture** — visible focus border (configurable color).
- **Built-in arrow keys** — Left/Right and Up/Down step the value by
  the slider's natural increment (or by `(max-min)/divisions` when set).
- **Type-to-replace** — when the slider has focus and the user types a
  digit, sign, or decimal point, the slider switches to an inline text
  buffer. Continue typing to accumulate. Enter commits, Esc cancels.
- **`def on_key(...)` scripting** — same render-plane projection
  protocol as `flet-einput`'s `EInputText`. The α `code` on a hosting
  EScalar with `ctype: ESlider` becomes the slider's keyboard handler.
- **Same command vocabulary** as EInputText:
  `commit / cancel / replace / insert / clear / select_all /
   move_to_next / move_to_prev / banner / beep / commit_value`.

Companion to `flet-einput`. Both extensions share
`flet_micropython` for client-side projection evaluation.
