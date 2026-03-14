"""
WindowManager - Floating window manager for Flet.

Provides draggable, resizable floating windows rendered as a Dart extension.
All drag/resize handled at 60fps in Dart; only final positions sent to Python.
"""
from .window_manager import WindowManager, FloatingWindow

__all__ = ["WindowManager", "FloatingWindow"]
