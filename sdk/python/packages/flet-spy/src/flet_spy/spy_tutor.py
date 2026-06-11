import json
from typing import Optional

import flet as ft


@ft.control("flet_spy_tutor")
class SpyTutor(ft.LayoutControl):
    """Spy tutor overlay — full-screen Stack rendered above the app.

    Add to page.overlay. Activate by setting active=True and lesson_yaml
    (the raw YAML string of a lesson file). The Dart widget parses and runs
    the lesson sequence autonomously. Python drives step advancement by
    calling emit() when relevant app events occur.

    Phase 2: Spy rendered as a placeholder snake emoji pane.
    Phase 3: Replace with RiveAnimation.asset('assets/spy.riv').
    """

    # Toggle the overlay on/off
    active: bool = False

    # Raw YAML string — Python reads the lesson file and assigns here.
    # Dart parses it on first assignment. Re-assigning restarts the lesson.
    lesson_yaml: str = ""

    # Whether the Spy character pane is visible (user can opt out at intro_splash)
    spy_visible: bool = True

    # Highlight position in screen pixels (Python-supplied).
    # Set w/h to 0 to clear the highlight.
    # Phase 4 will replace this with Dart GlobalKey lookup.
    highlight_x: float = 0.0
    highlight_y: float = 0.0
    highlight_w: float = 0.0
    highlight_h: float = 0.0

    # Event pipe: a SINGLE JSON string property so the whole event arrives
    # atomically on the Dart side. (An earlier design used separate
    # event_seq/event_type/event_data props, but Flet delivers property
    # changes incrementally — the int seq bump arrived and was consumed by
    # the Dart listener before the string props did, so the event was lost.
    # One property = one notification = no arrival-order race.)
    # Format: {"n": <monotonic nonce>, "type": <str>, "data": <obj>}
    event: str = ""

    def emit(self, event_type: str, data: Optional[dict] = None) -> None:
        """Emit a training event (e.g. widget_clicked, file_selected, code_executed)."""
        # Stash the nonce off the dataclass fields (not a control prop) so each
        # emit produces a distinct string — Flet only transmits CHANGED props,
        # so two identical events back-to-back must still differ.
        n = self.__dict__.get("_emit_nonce", 0) + 1
        self.__dict__["_emit_nonce"] = n
        self.event = json.dumps({"n": n, "type": event_type, "data": data or {}})
        self.update()

    def set_highlight(self, x: float, y: float, w: float, h: float) -> None:
        """Show amber highlight at the given screen-pixel rect."""
        self.highlight_x = x
        self.highlight_y = y
        self.highlight_w = w
        self.highlight_h = h
        self.update()

    def clear_highlight(self) -> None:
        """Remove the highlight overlay."""
        self.highlight_w = 0.0
        self.highlight_h = 0.0
        self.update()
