# flet-pdf-capture

Generic PDF **capture surface** for Flet. Flutter renders the PDF (pdfrx) and
owns the geometric drag-rectangle selection UX and a dynamic, agent-authored
button bar. The Python side owns extraction (text / table / OCR) and assembles
the result. The surface has **no domain logic** — it captures region(s); the
caller decides what they mean.

See `docs/HANDOFF_pdf_capture_surface.md` in the epyx-edd repo for the full
contract, milestones, and rationale.

This package is the thin transport layer: the `PdfCaptureSurface` control
(Python) ↔ the `PdfCaptureWidget` (Dart). The extraction services and the
agent-facing blocking tool live in `packages/epyx` (`epyx.pdf`,
`epyx.core.pdf_capture`).
