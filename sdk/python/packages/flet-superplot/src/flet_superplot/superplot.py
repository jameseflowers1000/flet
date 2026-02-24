"""
SuperPlot - High-performance charting for Flet.

API design mirrors SciChart for familiarity and potential migration path.
"""

from dataclasses import field
import json
from typing import Any, Optional, List

import flet as ft

from .axis import NumericAxis, LogarithmicAxis
from .series import FastLineSeries, XyScatterSeries
from .data import XyDataSeries

# Source version - must match Flutter SuperPlotControl.version
SOURCE_VERSION = '0.1.02'

# Track whether we've printed version info
_version_printed = False

def print_version_once(runtime_version: Optional[str] = None):
    """Print SuperPlot version info once."""
    global _version_printed
    if _version_printed:
        return
    _version_printed = True
    
    if runtime_version:
        match = "✓" if runtime_version == SOURCE_VERSION else f"✗ (source: {SOURCE_VERSION})"
        print(f"[SuperPlot] Runtime v{runtime_version} {match}")
    else:
        print(f"[SuperPlot] Source v{SOURCE_VERSION} (runtime version pending)")


@ft.control("flet_superplot")
class SuperPlot(ft.LayoutControl):
    """
    High-performance chart surface - equivalent to SciChart's SciChartSurface.
    
    Renders time series data with GPU acceleration via Flutter's CustomPainter.
    Designed for pixel-level compatibility with SciChart output.
    
    Example:
        ```python
        from flet_superplot import SuperPlot, NumericAxis, FastLineSeries, XyDataSeries
        
        plot = SuperPlot(
            x_axis=NumericAxis(axis_title="Time (s)"),
            y_axis=NumericAxis(axis_title="Amplitude", visible_range_min=0, visible_range_max=100),
            series=[
                FastLineSeries(
                    data_series=XyDataSeries(x_values=[0,1,2,3], y_values=[10,20,15,25]),
                    stroke_color="blue",
                    stroke_thickness=2,
                ),
            ],
        )
        ```
    """
    
    # JSON-encoded axis configuration - field names must match Flutter property names
    x_axis: Optional[str] = None
    y_axis: Optional[str] = None
    
    # JSON-encoded series list
    series: Optional[str] = None

    # JSON-encoded annotations list
    annotations: Optional[str] = None
    
    # Chart title
    title: Optional[str] = None
    
    # Background color (hex string like "#1c1c1e" or named color)
    background_color: str = "#1c1c1e"
    
    # Grid line visibility
    show_major_grid_lines: bool = True
    show_minor_grid_lines: bool = False
    
    # Grid line colors
    major_grid_line_color: str = "#333333"
    minor_grid_line_color: str = "#222222"
    
    # Runtime version - set by Flutter after render
    runtime_version: Optional[str] = None
    
    # Internal storage (renamed to avoid conflict with JSON property names)
    _x_axis_obj: Optional[NumericAxis] = field(default=None, repr=False, metadata={"skip": True})
    _y_axis_obj: Optional[NumericAxis] = field(default=None, repr=False, metadata={"skip": True})
    _series_list: List[FastLineSeries] = field(default_factory=list, repr=False, metadata={"skip": True})
    _annotations_list: List[Any] = field(default_factory=list, repr=False, metadata={"skip": True})
    
    def __post_init__(self, ref=None):
        super().__post_init__(ref)
        self._serialize_config()
    
    def _serialize_config(self):
        """Serialize axis and series configuration to JSON for Flutter."""
        if self._x_axis_obj:
            self.x_axis = json.dumps(self._x_axis_obj.to_dict())
        if self._y_axis_obj:
            self.y_axis = json.dumps(self._y_axis_obj.to_dict())
        if self._series_list:
            self.series = json.dumps([s.to_dict() for s in self._series_list])
        if self._annotations_list:
            self.annotations = json.dumps([a.to_dict() for a in self._annotations_list])
    
    def set_x_axis(self, value: NumericAxis):
        """Set the X axis configuration."""
        self._x_axis_obj = value
        if value:
            self.x_axis = json.dumps(value.to_dict())
    
    def set_y_axis(self, value: NumericAxis):
        """Set the Y axis configuration."""
        self._y_axis_obj = value
        if value:
            self.y_axis = json.dumps(value.to_dict())
    
    def set_series(self, value: List[FastLineSeries]):
        """Set the series list."""
        self._series_list = value
        if value:
            self.series = json.dumps([s.to_dict() for s in value])
    
    def add_series(self, new_series: FastLineSeries):
        """Add a renderable series to the chart."""
        self._series_list.append(new_series)
        self.series = json.dumps([s.to_dict() for s in self._series_list])
    
    def clear_series(self):
        """Remove all series from the chart."""
        self._series_list.clear()
        self.series = json.dumps([])

    def set_annotations(self, value: List[Any]):
        """Set the annotations list."""
        self._annotations_list = value
        if value:
            self.annotations = json.dumps([a.to_dict() for a in value])
        else:
            self.annotations = json.dumps([])

    def add_annotation(self, annotation: Any):
        """Add an annotation to the chart."""
        self._annotations_list.append(annotation)
        self.annotations = json.dumps([a.to_dict() for a in self._annotations_list])

    def clear_annotations(self):
        """Remove all annotations from the chart."""
        self._annotations_list.clear()
        self.annotations = json.dumps([])
    
    def update_data(self):
        """Trigger re-serialization and update after data changes."""
        self._serialize_config()


# Convenience factory matching SciChart's builder pattern
def create_surface(
    x_axis: NumericAxis,
    y_axis: NumericAxis,
    series: List[FastLineSeries],
    **kwargs
) -> SuperPlot:
    """
    Factory function for creating a SuperPlot surface.
    
    Mirrors SciChart's SciChartSurface.create() pattern.
    """
    plot = SuperPlot(**kwargs)
    plot.set_x_axis(x_axis)
    plot.set_y_axis(y_axis)
    plot.set_series(series)
    return plot
