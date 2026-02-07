"""
Data containers - mirrors SciChart's data series types.
"""

from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any, Union
import struct
import base64


@dataclass
class XyDataSeries:
    """
    XY data series - equivalent to SciChart's XyDataSeries.
    
    Holds paired X and Y values for line/scatter plots.
    Data is transmitted as base64-encoded binary for efficiency.
    """
    
    x_values: List[float] = field(default_factory=list)
    y_values: List[float] = field(default_factory=list)
    
    # Optional series name for legend
    series_name: Optional[str] = None
    
    def __post_init__(self):
        if len(self.x_values) != len(self.y_values):
            raise ValueError(
                f"x_values and y_values must have same length. "
                f"Got {len(self.x_values)} and {len(self.y_values)}"
            )
    
    @property
    def count(self) -> int:
        """Number of data points."""
        return len(self.x_values)
    
    def append(self, x: float, y: float):
        """Append a single point."""
        self.x_values.append(x)
        self.y_values.append(y)
    
    def extend(self, x_values: List[float], y_values: List[float]):
        """Extend with multiple points."""
        if len(x_values) != len(y_values):
            raise ValueError("x_values and y_values must have same length")
        self.x_values.extend(x_values)
        self.y_values.extend(y_values)
    
    def clear(self):
        """Remove all data points."""
        self.x_values.clear()
        self.y_values.clear()
    
    def get_x_range(self) -> tuple[float, float]:
        """Get min/max of X values."""
        if not self.x_values:
            return (0.0, 1.0)
        return (min(self.x_values), max(self.x_values))
    
    def get_y_range(self) -> tuple[float, float]:
        """Get min/max of Y values."""
        if not self.y_values:
            return (0.0, 1.0)
        return (min(self.y_values), max(self.y_values))
    
    def to_binary(self) -> bytes:
        """
        Encode data as binary (interleaved x,y pairs as float64).
        More efficient than JSON for large datasets.
        """
        data = []
        for x, y in zip(self.x_values, self.y_values):
            data.extend([x, y])
        return struct.pack(f'{len(data)}d', *data)
    
    def to_base64(self) -> str:
        """Encode data as base64 string for JSON transport."""
        return base64.b64encode(self.to_binary()).decode('ascii')
    
    @classmethod
    def from_binary(cls, data: bytes, series_name: Optional[str] = None) -> 'XyDataSeries':
        """Decode from binary format."""
        count = len(data) // 16  # 2 float64s per point
        values = struct.unpack(f'{count * 2}d', data)
        x_values = [values[i] for i in range(0, len(values), 2)]
        y_values = [values[i] for i in range(1, len(values), 2)]
        return cls(x_values=x_values, y_values=y_values, series_name=series_name)
    
    @classmethod
    def from_base64(cls, data: str, series_name: Optional[str] = None) -> 'XyDataSeries':
        """Decode from base64 string."""
        return cls.from_binary(base64.b64decode(data), series_name)
    
    def to_dict(self) -> Dict[str, Any]:
        """
        Serialize to dictionary for JSON encoding.
        Uses base64 for data to minimize JSON size.
        """
        return {
            "series_name": self.series_name,
            "count": self.count,
            "data_base64": self.to_base64(),
        }


@dataclass 
class OhlcDataSeries:
    """
    OHLC data series for candlestick/financial charts.
    
    Holds Open, High, Low, Close values for each time point.
    """
    
    x_values: List[float] = field(default_factory=list)  # Typically timestamps
    open_values: List[float] = field(default_factory=list)
    high_values: List[float] = field(default_factory=list)
    low_values: List[float] = field(default_factory=list)
    close_values: List[float] = field(default_factory=list)
    
    series_name: Optional[str] = None
    
    @property
    def count(self) -> int:
        return len(self.x_values)
    
    def to_dict(self) -> Dict[str, Any]:
        """Serialize to dictionary."""
        # Pack as interleaved: x, o, h, l, c
        data = []
        for i in range(self.count):
            data.extend([
                self.x_values[i],
                self.open_values[i],
                self.high_values[i],
                self.low_values[i],
                self.close_values[i],
            ])
        binary = struct.pack(f'{len(data)}d', *data)
        
        return {
            "type": "ohlc",
            "series_name": self.series_name,
            "count": self.count,
            "data_base64": base64.b64encode(binary).decode('ascii'),
        }
