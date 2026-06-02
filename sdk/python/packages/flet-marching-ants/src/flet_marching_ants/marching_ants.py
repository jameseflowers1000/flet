"""MarchingAnts — wrap any child control with an animated dashed border.

Same painter pattern as the ETB-19 grid ants (one dashed rect, four sides,
animated phase). Flet-side: a thin shim. All animation runs in Dart at
60 fps via AnimationController; Python pushes only static config.
"""
from typing import Optional

import flet as ft


@ft.control("flet_marching_ants")
class MarchingAnts(ft.LayoutControl):
    """Wrap `content` in an animated dashed border.

    When `active` is True the dashes are painted and the AnimationController
    advances; when False the border vanishes and the controller is paused
    (no frame cost). Style mirrors the grid painter so the popup hint and
    the picked cells in the grid feel like one connected experience.
    """

    content: Optional[ft.Control] = None
    active: bool = True

    color: str = "#57C66B"     # Neovim green — matches grid ants
    dash_length: float = 6.0
    gap_length: float = 4.0
    stroke_width: float = 1.6
    period_ms: int = 900       # one full animation loop

    # Padding between the child's rendered bounds and the dashed border.
    # Useful when the child is a short text — the dashes otherwise sit
    # flush against the glyphs and look cramped.
    border_inset: float = 2.0
    # Corner rounding for the border rect.
    border_radius: float = 4.0
