"""
Renderable series types - mirrors SciChart's series types.
"""

from dataclasses import dataclass, field
from typing import Optional, Dict, Any, List
from enum import Enum

from .data import XyDataSeries


class LineDrawMode(Enum):
    """How lines are drawn between points."""
    LINEAR = "linear"
    STEP = "step"
    SPLINE = "spline"


class PointMarkerType(Enum):
    """Point marker shapes."""
    NONE = "none"
    CIRCLE = "circle"
    SQUARE = "square"
    TRIANGLE = "triangle"
    CROSS = "cross"
    ELLIPSE = "ellipse"


@dataclass
class FastLineSeries:
    """
    Fast line series - equivalent to SciChart's FastLineRenderableSeries.
    
    Optimized for rendering large datasets with GPU acceleration.
    """
    
    # Data source
    data_series: Optional[XyDataSeries] = None
    
    # Line styling
    stroke_color: str = "#4083ff"  # SciChart-like blue
    stroke_thickness: float = 2.0
    
    # Line drawing mode
    draw_mode: LineDrawMode = LineDrawMode.LINEAR
    
    # Anti-aliasing (may impact performance)
    anti_aliasing: bool = True
    
    # Point markers (optional overlay on line)
    point_marker_type: PointMarkerType = PointMarkerType.NONE
    point_marker_size: float = 8.0
    point_marker_color: Optional[str] = None  # Defaults to stroke_color
    
    # Opacity (0.0 - 1.0)
    opacity: float = 1.0
    
    # Visibility
    is_visible: bool = True
    
    # Series ID for referencing
    series_id: Optional[str] = None

    # Display name for legend
    series_name: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary for JSON encoding."""
        return {
            "type": "fast_line",
            "series_id": self.series_id,
            "series_name": self.series_name,
            "data": self.data_series.to_dict() if self.data_series else None,
            "stroke_color": self.stroke_color,
            "stroke_thickness": self.stroke_thickness,
            "draw_mode": self.draw_mode.value,
            "anti_aliasing": self.anti_aliasing,
            "point_marker_type": self.point_marker_type.value,
            "point_marker_size": self.point_marker_size,
            "point_marker_color": self.point_marker_color or self.stroke_color,
            "opacity": self.opacity,
            "is_visible": self.is_visible,
        }


@dataclass
class XyScatterSeries:
    """
    Scatter series - equivalent to SciChart's XyScatterRenderableSeries.
    
    Renders individual points without connecting lines.
    """
    
    # Data source
    data_series: Optional[XyDataSeries] = None
    
    # Point styling
    point_color: str = "#ff6600"
    point_size: float = 8.0
    point_marker_type: PointMarkerType = PointMarkerType.CIRCLE
    
    # Border/stroke on points
    stroke_color: Optional[str] = None
    stroke_thickness: float = 1.0
    
    # Opacity
    opacity: float = 1.0
    
    # Visibility
    is_visible: bool = True
    
    # Series ID
    series_id: Optional[str] = None

    # Display name for legend
    series_name: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary for JSON encoding."""
        return {
            "type": "scatter",
            "series_id": self.series_id,
            "series_name": self.series_name,
            "data": self.data_series.to_dict() if self.data_series else None,
            "point_color": self.point_color,
            "point_size": self.point_size,
            "point_marker_type": self.point_marker_type.value,
            "stroke_color": self.stroke_color,
            "stroke_thickness": self.stroke_thickness,
            "opacity": self.opacity,
            "is_visible": self.is_visible,
        }


@dataclass
class FastMountainSeries:
    """
    Mountain/area series - equivalent to SciChart's FastMountainRenderableSeries.
    
    Fills the area between the line and a baseline (typically y=0).
    """
    
    # Data source
    data_series: Optional[XyDataSeries] = None
    
    # Line styling
    stroke_color: str = "#4083ff"
    stroke_thickness: float = 2.0
    
    # Fill styling
    fill_color: str = "#334083ff"  # Semi-transparent
    
    # Gradient fill (optional)
    gradient_start_color: Optional[str] = None
    gradient_end_color: Optional[str] = None
    
    # Baseline Y value
    zero_line_y: float = 0.0
    
    # Opacity
    opacity: float = 1.0
    
    # Visibility
    is_visible: bool = True
    
    series_id: Optional[str] = None

    # Display name for legend
    series_name: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary for JSON encoding."""
        return {
            "type": "mountain",
            "series_id": self.series_id,
            "series_name": self.series_name,
            "data": self.data_series.to_dict() if self.data_series else None,
            "stroke_color": self.stroke_color,
            "stroke_thickness": self.stroke_thickness,
            "fill_color": self.fill_color,
            "gradient_start_color": self.gradient_start_color,
            "gradient_end_color": self.gradient_end_color,
            "zero_line_y": self.zero_line_y,
            "opacity": self.opacity,
            "is_visible": self.is_visible,
        }
