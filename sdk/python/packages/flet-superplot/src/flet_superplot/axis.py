"""
Axis configuration - mirrors SciChart's axis types.
"""

from dataclasses import dataclass, field
from typing import Optional, Dict, Any
from enum import Enum


class AxisAlignment(Enum):
    """Axis alignment options."""
    LEFT = "left"
    RIGHT = "right"
    TOP = "top"
    BOTTOM = "bottom"


class AutoRange(Enum):
    """Auto-range behavior."""
    NEVER = "never"
    ONCE = "once"
    ALWAYS = "always"


@dataclass
class NumericAxis:
    """
    Numeric axis - equivalent to SciChart's NumericAxis.

    Supports linear scaling with configurable range, labels, and styling.
    Set ``axis_type='datetime'`` to make the Dart side treat values as
    epoch-millisecond timestamps and format ticks as readable dates.
    """

    # Axis type — 'numeric' (default) or 'datetime'. Datetime axes
    # interpret numeric values as ms-since-epoch and use date-aware tick
    # selection + formatting on the Dart side.
    axis_type: str = "numeric"

    # Title displayed along the axis
    axis_title: Optional[str] = None

    # Visible range (if None, auto-range is used)
    visible_range_min: Optional[float] = None
    visible_range_max: Optional[float] = None

    # Auto-range behavior
    auto_range: AutoRange = AutoRange.ALWAYS
    
    # Grow-by padding (fraction of range to add as padding)
    grow_by_min: float = 0.1
    grow_by_max: float = 0.1
    
    # Axis alignment
    axis_alignment: AxisAlignment = AxisAlignment.LEFT
    
    # Label formatting
    label_format: str = "{:.2f}"  # Python format string
    
    # Tick configuration
    major_tick_count: Optional[int] = None  # Auto if None
    minor_tick_count: int = 4
    
    # Styling
    axis_title_color: str = "#ffffff"
    axis_label_color: str = "#aaaaaa"
    axis_line_color: str = "#555555"
    major_tick_color: str = "#555555"
    minor_tick_color: str = "#333333"
    
    # Font sizes
    axis_title_font_size: float = 14.0
    axis_label_font_size: float = 12.0
    
    # Visibility
    draw_major_ticks: bool = True
    draw_minor_ticks: bool = True
    draw_major_grid_lines: bool = True
    draw_minor_grid_lines: bool = False
    draw_axis_labels: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary for JSON encoding."""
        return {
            "type": self.axis_type if self.axis_type in ("numeric", "datetime") else "numeric",
            "axis_title": self.axis_title,
            "visible_range_min": self.visible_range_min,
            "visible_range_max": self.visible_range_max,
            "auto_range": self.auto_range.value,
            "grow_by_min": self.grow_by_min,
            "grow_by_max": self.grow_by_max,
            "axis_alignment": self.axis_alignment.value,
            "label_format": self.label_format,
            "major_tick_count": self.major_tick_count,
            "minor_tick_count": self.minor_tick_count,
            "axis_title_color": self.axis_title_color,
            "axis_label_color": self.axis_label_color,
            "axis_line_color": self.axis_line_color,
            "major_tick_color": self.major_tick_color,
            "minor_tick_color": self.minor_tick_color,
            "axis_title_font_size": self.axis_title_font_size,
            "axis_label_font_size": self.axis_label_font_size,
            "draw_major_ticks": self.draw_major_ticks,
            "draw_minor_ticks": self.draw_minor_ticks,
            "draw_major_grid_lines": self.draw_major_grid_lines,
            "draw_minor_grid_lines": self.draw_minor_grid_lines,
            "draw_axis_labels": self.draw_axis_labels,
        }


@dataclass
class LogarithmicAxis:
    """
    Logarithmic axis - equivalent to SciChart's LogarithmicNumericAxis.
    
    Supports log10 scaling.
    """
    
    # Title displayed along the axis
    axis_title: Optional[str] = None
    
    # Visible range (in actual values, not log values)
    visible_range_min: Optional[float] = None
    visible_range_max: Optional[float] = None
    
    # Auto-range behavior
    auto_range: AutoRange = AutoRange.ALWAYS
    
    # Log base (typically 10)
    logarithmic_base: float = 10.0
    
    # Axis alignment
    axis_alignment: AxisAlignment = AxisAlignment.LEFT
    
    # Styling (same as NumericAxis)
    axis_title_color: str = "#ffffff"
    axis_label_color: str = "#aaaaaa"
    axis_line_color: str = "#555555"
    major_tick_color: str = "#555555"
    minor_tick_color: str = "#333333"
    
    axis_title_font_size: float = 14.0
    axis_label_font_size: float = 12.0
    
    draw_major_ticks: bool = True
    draw_minor_ticks: bool = True
    draw_major_grid_lines: bool = True
    draw_minor_grid_lines: bool = False
    draw_axis_labels: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary for JSON encoding."""
        return {
            "type": "logarithmic",
            "axis_title": self.axis_title,
            "visible_range_min": self.visible_range_min,
            "visible_range_max": self.visible_range_max,
            "auto_range": self.auto_range.value,
            "logarithmic_base": self.logarithmic_base,
            "axis_alignment": self.axis_alignment.value,
            "axis_title_color": self.axis_title_color,
            "axis_label_color": self.axis_label_color,
            "axis_line_color": self.axis_line_color,
            "major_tick_color": self.major_tick_color,
            "minor_tick_color": self.minor_tick_color,
            "axis_title_font_size": self.axis_title_font_size,
            "axis_label_font_size": self.axis_label_font_size,
            "draw_major_ticks": self.draw_major_ticks,
            "draw_minor_ticks": self.draw_minor_ticks,
            "draw_major_grid_lines": self.draw_major_grid_lines,
            "draw_minor_grid_lines": self.draw_minor_grid_lines,
            "draw_axis_labels": self.draw_axis_labels,
        }


@dataclass
class DateTimeAxis:
    """
    DateTime axis for time-series data.

    X values should be epoch milliseconds (float). Tick labels auto-format
    based on visible range (seconds → minutes → hours → days → months → years).
    """

    axis_title: Optional[str] = None
    visible_range_min: Optional[float] = None  # epoch ms
    visible_range_max: Optional[float] = None  # epoch ms
    auto_range: AutoRange = AutoRange.ALWAYS
    grow_by_min: float = 0.02
    grow_by_max: float = 0.02
    axis_alignment: AxisAlignment = AxisAlignment.BOTTOM
    major_tick_count: Optional[int] = None

    # Styling
    axis_title_color: str = "#ffffff"
    axis_label_color: str = "#aaaaaa"
    axis_line_color: str = "#555555"
    major_tick_color: str = "#555555"
    minor_tick_color: str = "#333333"
    axis_title_font_size: float = 14.0
    axis_label_font_size: float = 12.0
    draw_major_ticks: bool = True
    draw_minor_ticks: bool = True
    draw_major_grid_lines: bool = True
    draw_minor_grid_lines: bool = False
    draw_axis_labels: bool = True

    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary for JSON encoding."""
        return {
            "type": "datetime",
            "axis_title": self.axis_title,
            "visible_range_min": self.visible_range_min,
            "visible_range_max": self.visible_range_max,
            "auto_range": self.auto_range.value,
            "grow_by_min": self.grow_by_min,
            "grow_by_max": self.grow_by_max,
            "major_tick_count": self.major_tick_count,
            "axis_alignment": self.axis_alignment.value,
            "axis_title_color": self.axis_title_color,
            "axis_label_color": self.axis_label_color,
            "axis_line_color": self.axis_line_color,
            "major_tick_color": self.major_tick_color,
            "minor_tick_color": self.minor_tick_color,
            "axis_title_font_size": self.axis_title_font_size,
            "axis_label_font_size": self.axis_label_font_size,
            "draw_major_ticks": self.draw_major_ticks,
            "draw_minor_ticks": self.draw_minor_ticks,
            "draw_major_grid_lines": self.draw_major_grid_lines,
            "draw_minor_grid_lines": self.draw_minor_grid_lines,
            "draw_axis_labels": self.draw_axis_labels,
        }
