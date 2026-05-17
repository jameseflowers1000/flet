"""VimEditor — Flet wrapper around the lab's UnifiedEditor.

Surface kept deliberately small: the host gives us
- the initial buffer text + LSP-document URI,
- WebSocket URLs the Dart side needs to reach the LSP and the nvim
  proxy,
and we fire `on_save` with the latest buffer text whenever the user
saves (`:w` in vim, `Cmd-S` / save button in EZ). The host applies
the new text back to whatever the buffer represents (a control's
`code` attribute, a per-cell formula, a scratch file).

Mirrors the EditSession contract from the lab; production callers
never need to know about the EZ/Vim split, the embedded nvim, or
anything below.
"""

from typing import Optional

import flet as ft


@ft.control("vim_editor")
class VimEditor(ft.LayoutControl):
    """Unified code editor (Flutter-native EZ + embedded nvim)."""

    # ── content ────────────────────────────────────────────────────
    initial_text: str = ""
    """Initial buffer text. Re-setting it after mount replaces the
    buffer (loses the in-flight cursor + dirty state)."""

    label: str = ""
    """Display name shown in the chrome (toolbar). Free-form."""

    uri: str = ""
    """LSP document URI. Drives `resolve_context()` on the pygls
    side — control name, attribute, optional column. Same shape as
    the lab uses (e.g. `file:///tmp/epyx_edit_o_amort_code_code.py`)."""

    # ── transports ─────────────────────────────────────────────────
    lsp_ws_url: Optional[str] = None
    """WebSocket URL for the pygls server. None disables LSP-driven
    features (completions, hover, diagnostics)."""

    nvim_ws_url: Optional[str] = None
    """WebSocket URL for the nvim stdio bridge. None disables vim
    mode (the user can still use the EZ side)."""

    # ── behavior ──────────────────────────────────────────────────
    initial_mode: str = "native"
    """`'native'` (EZ) or `'nvim'` (Vim). Defaults to EZ — friendlier
    for newcomers."""

    debug: bool = False
    """When true the Dart side emits `[lab.diag]` / `[vim.complete]` /
    `[lsp.recv]` console traces — useful while bringing up new flows."""

    # ── events ─────────────────────────────────────────────────────
    # Implemented as method-style events on Flet's control protocol.
    # The Dart side calls `triggerEvent("save", {"text": ...})` on
    # buffer save; we forward the text into the user's callback.

    on_save: Optional[ft.ControlEventHandler["VimEditor"]] = None
    """Fired when the user saves the buffer (`:w` in vim, `Cmd-S`
    in EZ). The new full text is in `event.data['text']`."""

    on_cancel: Optional[ft.ControlEventHandler["VimEditor"]] = None
    """Fired when the user dismisses the editor without saving."""

    on_mode_change: Optional[ft.ControlEventHandler["VimEditor"]] = None
    """Fired when the user toggles between EZ and Vim. The new mode
    string (`'native'` or `'nvim'`) is in `event.data`. The host can
    persist this so the next `/edit` opens in the same mode."""
