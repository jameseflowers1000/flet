"""
SuperPlot - High-performance charting for Flet.

API compatible with SciChart for easy migration and side-by-side comparison.
"""

from .superplot import SuperPlot, create_surface, SOURCE_VERSION, print_version_once
from .axis import NumericAxis, LogarithmicAxis, DateTimeAxis, AxisAlignment, AutoRange
from .series import (
    FastLineSeries,
    XyScatterSeries,
    FastMountainSeries,
    LineDrawMode,
    PointMarkerType,
)
from .data import XyDataSeries, OhlcDataSeries
from .annotations import HorizontalLine, VerticalLine, TextAnnotation, BoxAnnotation
from .bridge import evaluate_plot_code, BRIDGE_SOURCE

__all__ = [
    # Main control
    "SuperPlot",
    "create_surface",
    "SOURCE_VERSION",
    "print_version_once",
    # Axes
    "NumericAxis",
    "LogarithmicAxis",
    "DateTimeAxis",
    "AxisAlignment",
    "AutoRange",
    # Series
    "FastLineSeries",
    "XyScatterSeries",
    "FastMountainSeries",
    "LineDrawMode",
    "PointMarkerType",
    # Data
    "XyDataSeries",
    "OhlcDataSeries",
    # Annotations
    "HorizontalLine",
    "VerticalLine",
    "TextAnnotation",
    "BoxAnnotation",
    # Bridge API
    "evaluate_plot_code",
    "BRIDGE_SOURCE",
]
