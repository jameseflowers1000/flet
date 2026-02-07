"""
SuperPlot - High-performance charting for Flet.

API compatible with SciChart for easy migration and side-by-side comparison.
"""

from .superplot import SuperPlot, create_surface
from .axis import NumericAxis, LogarithmicAxis, AxisAlignment, AutoRange
from .series import (
    FastLineSeries,
    XyScatterSeries,
    FastMountainSeries,
    LineDrawMode,
    PointMarkerType,
)
from .data import XyDataSeries, OhlcDataSeries

__all__ = [
    # Main control
    "SuperPlot",
    "create_surface",
    # Axes
    "NumericAxis",
    "LogarithmicAxis",
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
]
