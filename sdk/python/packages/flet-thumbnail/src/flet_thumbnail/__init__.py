"""
FletThumbnail - Capture thumbnails of Flet controls via RepaintBoundary.

Invisible service widget that registers control IDs for capture and
returns PNG screenshots via invoke_method.
"""

from .thumbnail import ThumbnailService

__all__ = [
    "ThumbnailService",
]
