"""
Chart annotations — reference lines, text labels, and box regions.
"""

from dataclasses import dataclass
from typing import Optional, Dict, Any


@dataclass
class HorizontalLine:
    """Horizontal reference line at a Y value."""
    y: float
    color: str = "#FFFF00"
    thickness: float = 1.0
    dash_pattern: Optional[str] = None  # "5,3" = 5px dash, 3px gap
    label: Optional[str] = None
    label_color: str = "#FFFFFF"
    opacity: float = 0.8

    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "horizontal_line",
            "y": self.y,
            "color": self.color,
            "thickness": self.thickness,
            "dash_pattern": self.dash_pattern,
            "label": self.label,
            "label_color": self.label_color,
            "opacity": self.opacity,
        }


@dataclass
class VerticalLine:
    """Vertical reference line at an X value."""
    x: float
    color: str = "#FFFF00"
    thickness: float = 1.0
    dash_pattern: Optional[str] = None
    label: Optional[str] = None
    label_color: str = "#FFFFFF"
    opacity: float = 0.8

    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "vertical_line",
            "x": self.x,
            "color": self.color,
            "thickness": self.thickness,
            "dash_pattern": self.dash_pattern,
            "label": self.label,
            "label_color": self.label_color,
            "opacity": self.opacity,
        }


@dataclass
class TextAnnotation:
    """Text label at a data coordinate."""
    x: float
    y: float
    text: str
    color: str = "#FFFFFF"
    font_size: float = 12.0
    background_color: Optional[str] = None
    opacity: float = 1.0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "text",
            "x": self.x,
            "y": self.y,
            "text": self.text,
            "color": self.color,
            "font_size": self.font_size,
            "background_color": self.background_color,
            "opacity": self.opacity,
        }


@dataclass
class BoxAnnotation:
    """Highlighted rectangular region in data coordinates."""
    x_min: float
    x_max: float
    y_min: float
    y_max: float
    fill_color: str = "#334488FF"
    border_color: Optional[str] = None
    border_thickness: float = 1.0
    opacity: float = 0.3

    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": "box",
            "x_min": self.x_min,
            "x_max": self.x_max,
            "y_min": self.y_min,
            "y_max": self.y_max,
            "fill_color": self.fill_color,
            "border_color": self.border_color,
            "border_thickness": self.border_thickness,
            "opacity": self.opacity,
        }
