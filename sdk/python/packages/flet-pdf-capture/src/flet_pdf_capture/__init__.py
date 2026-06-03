"""flet-pdf-capture — PDF capture surface control.

Flutter renders (pdfrx) + owns geometric selection + the dynamic button
bar; Python owns extraction. This package is only the transport control;
extraction + the agent-facing blocking tool live in `epyx.pdf` /
`epyx.core.pdf_capture`.
"""

from .pdf_capture import PdfCaptureSurface

__all__ = [
    "PdfCaptureSurface",
]
