# SuperPlot - High-Performance Charts for Flet

SuperPlot is a Flutter-native charting control for Flet, designed for pixel-level compatibility with SciChart. It provides GPU-accelerated rendering via Flutter's CustomPainter, enabling smooth visualization of large datasets.

## Features (Checkpoint 1 - MVP)

- ✅ Line series rendering
- ✅ Numeric axes with auto-ranging
- ✅ Grid lines
- ✅ Axis labels and titles
- ✅ Multiple series support
- ✅ SciChart-compatible API

## Roadmap (Checkpoint 2 - Performance)

- 🔲 LTTB/M4 decimation for large datasets
- 🔲 GPU-optimized batch rendering
- 🔲 Level-of-detail (LOD) for zoom
- 🔲 Pan/zoom interactions
- 🔲 Mouse wheel zoom

## Installation

```bash
pip install flet-superplot
```

## Usage

```python
import flet as ft
from flet_superplot import (
    SuperPlot, 
    NumericAxis, 
    FastLineSeries, 
    XyDataSeries
)
import math

def main(page: ft.Page):
    # Generate sine wave data
    x_values = [i * 0.01 for i in range(1000)]
    y_values = [50 + 50 * math.sin(2 * math.pi * 2 * x) for x in x_values]
    
    plot = SuperPlot(
        width=800,
        height=600,
    )
    plot.x_axis = NumericAxis(
        axis_title="Time (s)",
        visible_range_min=0,
        visible_range_max=10,
    )
    plot.y_axis = NumericAxis(
        axis_title="Amplitude",
        visible_range_min=0,
        visible_range_max=100,
    )
    plot.series = [
        FastLineSeries(
            data_series=XyDataSeries(x_values=x_values, y_values=y_values),
            stroke_color="#4083ff",
            stroke_thickness=2,
        ),
    ]
    
    page.add(plot)

ft.app(target=main)
```

## Test Harness for Pixel Comparison

The test harness allows automated visual comparison between SuperPlot and SciChart using Playwright.

### Setup

1. Install Playwright:
   ```bash
   pip install playwright
   playwright install chromium
   ```

2. Serve the test files:
   ```bash
   cd tests/harness
   python -m http.server 8080
   ```

3. Run the comparison test:
   ```bash
   python tests/harness/compare.py
   ```

### Files

- `tests/harness/scichart_reference.html` - SciChart reference implementation
- `tests/harness/compare.py` - Playwright comparison script

## Architecture

### Python Side
- `SuperPlot` - Main control (Flet widget)
- `NumericAxis`, `LogarithmicAxis` - Axis configuration
- `FastLineSeries`, `XyScatterSeries` - Series types
- `XyDataSeries` - Data container with binary encoding

### Flutter Side
- `SuperPlotControl` - Flet control bridge
- `ChartPainter` - CustomPainter for GPU rendering
- `AxisModel`, `SeriesModel` - Configuration models

## API Compatibility with SciChart

| SciChart | SuperPlot |
|----------|-----------|
| `SciChartSurface` | `SuperPlot` |
| `NumericAxis` | `NumericAxis` |
| `LogarithmicNumericAxis` | `LogarithmicAxis` |
| `FastLineRenderableSeries` | `FastLineSeries` |
| `XyScatterRenderableSeries` | `XyScatterSeries` |
| `XyDataSeries` | `XyDataSeries` |

## License

Apache 2.0
