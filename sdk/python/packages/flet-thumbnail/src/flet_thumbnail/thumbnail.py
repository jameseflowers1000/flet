"""
ThumbnailService - Invisible control for capturing widget thumbnails.

Uses RepaintBoundary.toImage() on the Dart side to capture any registered
control as a PNG. The control renders as SizedBox.shrink() — invisible.

Usage:
    svc = ThumbnailService()
    page.overlay.append(svc)
    page.update()

    svc.control_ids = json.dumps([42, 57, 103])
    svc.update()

    png_bytes = await svc.capture(control_id=42, width=160, height=120)
"""

import json
from typing import List, Optional

import flet as ft
from flet.controls.types import Number


@ft.control("flet_thumbnail")
class ThumbnailService(ft.Control):
    """Invisible service widget for capturing control thumbnails."""

    # JSON array of control IDs to register for capture
    control_ids: Optional[str] = None

    # Default thumbnail dimensions
    thumb_width: Number = 160
    thumb_height: Number = 120

    def register_controls(self, ids: List[int]):
        """Register control IDs for thumbnail capture."""
        self.control_ids = json.dumps(ids)

    async def capture(
        self,
        control_id: int,
        width: Optional[Number] = None,
        height: Optional[Number] = None,
        pixel_ratio: Optional[Number] = None,
    ) -> bytes:
        """
        Capture a thumbnail of the specified control.

        Args:
            control_id: The Flet control ID to capture.
            width: Target width in logical pixels (default: thumb_width).
            height: Target height in logical pixels (default: thumb_height).
            pixel_ratio: Device pixel ratio for capture (default: 0.5).

        Returns:
            PNG image bytes.
        """
        return await self._invoke_method(
            "capture",
            arguments={
                "control_id": control_id,
                "width": width or self.thumb_width,
                "height": height or self.thumb_height,
                "pixel_ratio": pixel_ratio or 0.5,
            },
        )
