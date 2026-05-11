# flet-vim-editor

Unified code editor (EZ + embedded nvim) shipped as a Flet extension.
Origin: `experiments/code_editor_lab/` — graduated to a Flet control.

Python:

```python
from flet_vim_editor import VimEditor

editor = VimEditor(
    initial_text="...",
    uri="file:///tmp/foo.py",
    on_save=lambda new_text: ...,
)
page.add(editor)
```

## Architecture

- **Dart**: same UnifiedEditor + NvimEmbedView + LspClient + popup
  surfaces from the lab, namespaced under
  `lib/src/`.
- **nvim transport**: WebSocket → `lab_chrome_proxy.py`-style bridge
  (lives container-side in production, host-side as a placeholder in
  the lab dev harness).
- **LSP**: pygls-α connected via WebSocket, same as the lab.

## Why a new extension and not a `flet-code-editor` upgrade

`flet-code-editor` wraps `flutter_code_editor` and is used by other
flows. Replacing its guts would break those. This is a separate
control type, free to evolve.
