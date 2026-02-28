"""
ResizablePanel - Client-side resizable panel control.

Drag is handled entirely in Dart at 60fps with zero WebSocket traffic.
Only the final panel sizes are sent to Python on drag_end via updateControl.
"""

from dataclasses import field
from typing import Optional, List

import flet as ft


@ft.control("resizable_panel")
class ResizablePanel(ft.LayoutControl):
    """
    A panel container that allows resizing child controls by dragging dividers.

    Supports both horizontal (left-to-right) and vertical (top-to-bottom)
    orientations. Drag is handled entirely client-side at 60fps.

    Example:
        ```python
        panel = ResizablePanel(
            controls=[panel_a, panel_b, panel_c],
            initial_sizes='[1, 3, 1]',
            orientation='horizontal',
        )
        ```
    """

    controls: List[ft.Control] = field(default_factory=list)
    """Child controls to arrange in the panel."""

    initial_sizes: Optional[str] = None
    """JSON-encoded list of flex ratios, e.g. '[1, 5]'."""

    orientation: str = "horizontal"
    """'horizontal' (left-to-right) or 'vertical' (top-to-bottom)."""

    divider_width: int = 8
    """Width/height of the divider handle in pixels."""

    divider_color: str = "#000000"
    """Hex color of the divider at rest."""

    indicator_color: str = "#42A5F5"
    """Hex color of the divider during active drag."""

    min_panel_size: int = 50
    """Minimum panel size in pixels."""

    panel_sizes: Optional[str] = None
    """JSON-encoded list of current flex ratios. Updated by Dart on drag_end."""
