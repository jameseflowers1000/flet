"""PdfCaptureSurface — Flet control bridging to the Dart `pdfrx` surface.

Transport only. The Dart widget renders the PDF, draws the debug overlay
(milestone 2), and later owns the geometric drag-rectangle selection +
the agent-authored button bar. Python pushes the document bytes and the
extracted fragments down; Dart sends committed region geometry back up.

Coordinate convention for every bbox crossing this control: canonical
(x0, top, x1, bottom), top-left origin, y-down, PDF points — see
`epyx.pdf` (the extraction side) for why.

Data direction summary:

  Python → Dart (imperative, msgpack — binary-safe, no string-drop):
    * load_document(bytes, page_sizes)   push the PDF for pdfrx to render
    * set_fragments(fragments)           push fragment bboxes for overlay
    * set_debug_overlay(on)              toggle the alignment debug overlay
  Dart → Python (events):
    * on_document_changed                user opened a new PDF via picker
    * on_result                          user pressed a button (milestone 4)
  Dart → Python (pull, msgpack return):
    * get_document_bytes()               fetch the picker-loaded PDF bytes
"""

from typing import List, Optional

import flet as ft


@ft.control("flet_pdf_capture")
class PdfCaptureSurface(ft.LayoutControl):
    """PDF capture surface. Fill it to your overlay's bounds."""

    # ── request config (agent-authored; Python → Dart props) ─────────
    selection_mode: str = "single"
    """`'single'` (each drag replaces the prior selection) or `'multi'`
    (drags accumulate)."""

    buttons: Optional[str] = None
    """JSON array of CaptureButton dicts `{id,label,mode,role}` rendered
    in the dynamic button bar (milestone 4). None → no bar yet."""

    initial_page: int = 0
    """0-based page to show first."""

    instructions: Optional[str] = None
    """Optional banner text shown to the user."""

    debug_overlay: bool = False
    """When true, the surface draws every fragment bbox over the rendered
    page to verify coordinate alignment (milestone 2)."""

    # ── events (Dart → Python) ───────────────────────────────────────
    on_document_changed: Optional[ft.ControlEventHandler["PdfCaptureSurface"]] = None
    """Fired when the user opens a new PDF from the surface's file picker.
    `event.data` carries `{page_count}`. The host then pulls the bytes via
    `get_document_bytes()`, re-extracts, and pushes fragments back."""

    on_result: Optional[ft.ControlEventHandler["PdfCaptureSurface"]] = None
    """Fired when the user presses a button (milestone 4). `event.data`
    carries `{buttonId, cancelled, selections:[{mode?,page,rect_pts}]}` —
    geometry only; Python does the extraction."""

    # ── imperative pushes (Python → Dart) ────────────────────────────
    async def load_document(self, data: bytes,
                            page_sizes: Optional[List[List[float]]] = None) -> None:
        """Push PDF bytes for pdfrx to render. `page_sizes` is the optional
        per-page [[w_pts, h_pts], ...] from the extractor — handed to the
        Dart transform as a cross-check against pdfrx's own page metrics."""
        await self._invoke_method(
            "load_document",
            arguments={"bytes": data, "page_sizes": page_sizes or []},
        )

    async def set_fragments(self, fragments: List[dict]) -> None:
        """Push fragment bboxes (list of `{page,text,x0,top,x1,bottom,
        source}`) for the overlay / live highlight. Sent via method args
        (msgpack) rather than a property to dodge the long-string-drop
        gotcha on large documents."""
        await self._invoke_method(
            "set_fragments", arguments={"fragments": fragments},
        )

    async def set_debug_overlay(self, on: bool) -> None:
        """Toggle the fragment-bbox alignment overlay."""
        await self._invoke_method(
            "set_debug_overlay", arguments={"on": bool(on)},
        )

    # ── imperative pulls (Dart → Python) ─────────────────────────────
    async def get_document_bytes(self) -> Optional[bytes]:
        """Pull the bytes of the PDF the user opened via the surface's file
        picker, so Python can extract from the same document the front-end
        is rendering. Returns None if no document is loaded."""
        return await self._invoke_method("get_document_bytes")
