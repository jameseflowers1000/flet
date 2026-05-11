"""Flet extension that ships the lab's UnifiedEditor (EZ + embedded
nvim, atom-one-dark, LSP completions, hover docs) as a single
LayoutControl. See `vim_editor.py` for the surface."""

from .vim_editor import VimEditor

__all__ = ["VimEditor"]
