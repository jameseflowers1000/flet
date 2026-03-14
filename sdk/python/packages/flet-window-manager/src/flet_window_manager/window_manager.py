"""
WindowManager and FloatingWindow controls.

WindowManager is added to page.overlay. It manages a list of FloatingWindow
children, each rendered as a draggable, resizable chrome window in Dart.

All drag/resize is handled entirely client-side at 60fps.
Only final positions are sent to Python via updateControl on gesture end.
"""

from dataclasses import field
from typing import Optional, List

import flet as ft


@ft.control("window_manager")
class WindowManager(ft.LayoutControl):
    """Invisible manager added to page.overlay. Children are FloatingWindows."""

    controls: List[ft.Control] = field(default_factory=list)
    """FloatingWindow children managed by this window manager."""


@ft.control("floating_window")
class FloatingWindow(ft.LayoutControl):
    """A single floating, draggable, resizable window."""

    controls: List[ft.Control] = field(default_factory=list)
    """Child controls rendered inside the window chrome."""

    win_left: float = 100.0
    """X position of the window (pixels from left edge of viewport)."""

    win_top: float = 100.0
    """Y position of the window (pixels from top of viewport)."""

    win_width: float = 800.0
    """Width of the window in pixels."""

    win_height: float = 400.0
    """Height of the window in pixels."""

    title: str = ""
    """Title displayed in the window's title bar."""

    minimized: bool = False
    """Whether the window is minimized (hidden via opacity)."""

    maximized: bool = False
    """Whether the window is maximized to fill viewport."""

    win_visible: bool = True
    """Whether the window is visible. Uses opacity, not visible=False."""

    title_bar_color: str = "#1E1E2E"
    """Background color of the title bar."""

    chrome_color: str = "#26252D"
    """Background color of the window body."""

    on_close: Optional[ft.ControlEventHandler] = None
    """Called when the close button is clicked."""

    on_move_end: Optional[ft.ControlEventHandler] = None
    """Called when drag ends, with updated position."""

    on_resize_end: Optional[ft.ControlEventHandler] = None
    """Called when resize ends, with updated dimensions."""
