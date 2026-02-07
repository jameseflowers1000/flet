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
    
    # JSON-encoded axis configuration
    x_axis_json: Optional[str] = field(default=None, metadata={"data_field": "x_axis"})
    y_axis_json: Optional[str] = field(default=None, metadata={"data_field": "y_axis"})
    
    # JSON-encoded series list
    series_json: Optional[str] = field(default=None, metadata={"data_field": "series"})
    
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
    
    # Internal storage
    _x_axis: Optional[NumericAxis] = field(default=None, repr=False, metadata={"skip": True})
    _y_axis: Optional[NumericAxis] = field(default=None, repr=False, metadata={"skip": True})
    _series: List[FastLineSeries] = field(default_factory=list, repr=False, metadata={"skip": True})
    
    def __post_init__(self, ref=None):
        super().__post_init__(ref)
        self._serialize_config()
    
    def _serialize_config(self):
        """Serialize axis and series configuration to JSON for Flutter."""
        if self._x_axis:
            self.x_axis_json = json.dumps(self._x_axis.to_dict())
        if self._y_axis:
            self.y_axis_json = json.dumps(self._y_axis.to_dict())
        if self._series:
            self.series_json = json.dumps([s.to_dict() for s in self._series])
    
    @property
    def x_axis(self) -> Optional[NumericAxis]:
        return self._x_axis
    
    @x_axis.setter
    def x_axis(self, value: NumericAxis):
        self._x_axis = value
        if value:
            self.x_axis_json = json.dumps(value.to_dict())
    
    @property
    def y_axis(self) -> Optional[NumericAxis]:
        return self._y_axis
    
    @y_axis.setter
    def y_axis(self, value: NumericAxis):
        self._y_axis = value
        if value:
            self.y_axis_json = json.dumps(value.to_dict())
    
    @property
    def series(self) -> List[FastLineSeries]:
        return self._series
    
    @series.setter
    def series(self, value: List[FastLineSeries]):
        self._series = value
        if value:
            self.series_json = json.dumps([s.to_dict() for s in value])
    
    def add_series(self, series: FastLineSeries):
        """Add a renderable series to the chart."""
        self._series.append(series)
        self.series_json = json.dumps([s.to_dict() for s in self._series])
    
    def clear_series(self):
        """Remove all series from the chart."""
        self._series.clear()
        self.series_json = json.dumps([])
    
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
    plot.x_axis = x_axis
    plot.y_axis = y_axis
    plot.series = series
    return plot
