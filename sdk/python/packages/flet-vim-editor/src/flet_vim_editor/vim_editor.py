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

    autofocus: bool = False
    """When true, the editor claims keyboard focus on mount. The side
    panel deliberately does NOT autofocus (so the doclet's currently-
    focused control keeps the cursor when Cmd-E opens the editor), but
    the ETB-09b cell popup DOES — the user just hit Cmd-E expecting
    to type into the formula immediately."""

    # ── ETB-19 programmatic insertion at cursor ───────────────────
    # Excel-style cell-reference picking: when the user clicks a grid
    # cell while the cell-formula popup is open, the orchestrator wants
    # to drop that cell's reference text at the editor's cursor. The
    # Python side calls `insert_at_cursor(text)`; we bump
    # `pending_insert_seq` and stuff the text in `pending_insert_text`.
    # The Dart side watches `pending_insert_seq` — when it changes, it
    # inserts the text at the current cursor (via `nvim_input` in vim
    # mode, via the TextEditingController in EZ). Same primitive for
    # both modes, same UX.
    pending_insert_seq: int = 0
    pending_insert_text: str = ""
    # ETB-19: when > 0, the Dart side deletes this many characters
    # immediately before the cursor BEFORE inserting `pending_insert_text`.
    # Used by the orchestrator's "replace previous pick" path so each
    # new cell-pick swaps in a fresh reference instead of appending.
    pending_insert_replace_len: int = 0

    def insert_at_cursor(self, text: str, replace_len: int = 0) -> None:
        """Insert `text` at the editor's current cursor. If `replace_len`
        is non-zero, delete that many characters immediately before the
        cursor first (Excel-style: each new pick replaces the previously
        picked reference). Pure-delete form: `insert_at_cursor('',
        replace_len=N)` removes N chars before cursor — used by the
        ETB-19 ESC handler to back out the most recent pick.
        Used by the cell-formula popup's pick path."""
        if not text and replace_len <= 0:
            return  # nothing to do
        self.pending_insert_replace_len = int(replace_len or 0)
        self.pending_insert_seq = int(self.pending_insert_seq or 0) + 1
        self.pending_insert_text = text
        try:
            self.update()
        except Exception:
            pass

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
