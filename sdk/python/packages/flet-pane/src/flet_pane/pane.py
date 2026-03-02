"""
PaneControl - Custom Dart pane with 60fps gutter alley.

The gutter hover expand/collapse runs entirely in Dart (AnimationController)
with zero Python WebSocket round-trips. LOD via ListView.builder ensures
hundreds of controls stay performant.

Gutter metadata (icon base64, indicator color) is passed as a JSON list
on the PaneControl itself via the `gutter_metadata` property. Each entry
maps by index to the corresponding child control:

    pane = PaneControl(controls=[ctrl_a, ctrl_b])
    pane.gutter_metadata = json.dumps([
        {"gutter_icon": "<base64 PNG>", "gutter_color": "#4410AA"},
        {"gutter_icon": "<base64 PNG>", "gutter_color": "#E91E63"},
    ])
"""

import json
from dataclasses import field
from typing import List, Optional

import flet as ft


@ft.control("flet_pane")
class PaneControl(ft.LayoutControl):
    """Custom pane with gutter alley, LOD, and scroll arrows.

    Hover expand/collapse is handled in Dart at 60fps. Python only
    receives on_gutter_tap and on_scroll events when needed.
    """

    # Layout
    bgcolor: Optional[str] = None
    border_radius: Optional[float] = None
    orientation: str = 'vertical'     # 'vertical' = gutter left, 'horizontal' = gutter bottom
    gutter_width_idle: float = 18
    gutter_width_hover: float = 66
    gutter_color: str = '#0F1215'
    animation_ms: int = 180
    spacing: float = 0

    # Padding (right, top, bottom — left is managed by gutter)
    padding_right: float = 8
    padding_top: float = 4
    padding_bottom: float = 4

    # Scroll arrow config
    arrow_size: float = 32
    arrow_fade_ms: int = 150
    dim_opacity: float = 0.3

    # Children
    controls: List[ft.Control] = field(default_factory=list)

    # Per-child gutter metadata — JSON list of {gutter_icon, gutter_color}
    # Indexed by position matching controls list order.
    gutter_metadata: Optional[str] = None

    # MicroPython formula strings — evaluated client-side at 60fps.
    # Each formula receives a context dict with the item's metadata fields.
    # Use Python f-string syntax: f"#FF0000" or f"#{r:02x}{g:02x}{b:02x}"
    gutter_color_formula: Optional[str] = None
    gutter_width_formula: Optional[str] = None
    gutter_opacity_formula: Optional[str] = None

    # Events
    on_gutter_tap: Optional[ft.ControlEventHandler] = None
    on_scroll: Optional[ft.ControlEventHandler] = None

    def set_gutter_metadata_from_list(self, metadata: list):
        """Convenience: serialize a list of dicts to the gutter_metadata JSON string."""
        self.gutter_metadata = json.dumps(metadata)
