# SuperPlot

High-performance native Flutter charting widget. Replacement for SciChart (licensing issues) and Syncfusion (doesn't scale). Uses SciChart as visual reference oracle.

## Project Status

### Checkpoint 1: Visual Match (COMPLETE)
- Static chart matching SciChart layout
- Two sine wave test datasets
- Matching axes, grid, colors
- Playwright-based pixel comparison harness

### Checkpoint 2: Performance (CURRENT)
Target: 100K+ points with smooth interaction

**Decimation algorithms to implement:**
- LTTB (Largest Triangle Three Buckets) - O(n) visual-preserving downsampling
- M4 - min/max/first/last per pixel column for "error-free" visualization  
- MinMaxLTTB - 30x faster than LTTB via MinMax preselection

**GPU optimization:**
- WebGL batching for point rendering
- Impeller/Skia acceleration via CustomPainter
- LOD (Level of Detail) based on zoom level

### Checkpoint 3: Features (FUTURE)
- Mouse wheel zoom
- Butter-smooth pan/zoom gestures
- Log/linear axis switching
- Tooltips on hover
- Event callbacks (onZoom, onPan, onSelect)
- Gradient fills for area charts
- Spark plots (minimal axes)

## Key Files

**Flutter (rendering):**
- `src/flutter/flet_superplot/lib/src/painters/chart_painter.dart` - Main CustomPainter
- `src/flutter/flet_superplot/lib/src/models/axis_model.dart` - Axis config
- `src/flutter/flet_superplot/lib/src/models/series_model.dart` - Series + DataPoints
- `src/flutter/flet_superplot/lib/main.dart` - Standalone test app

**Python API:**
- `src/flet_superplot/superplot.py` - Main control
- `src/flet_superplot/axis.py` - NumericAxis, LogarithmicAxis
- `src/flet_superplot/series.py` - FastLineSeries, XyScatterSeries
- `src/flet_superplot/data.py` - XyDataSeries with base64 binary encoding

**Test harness:**
- `tests/harness/compare.py` - Playwright screenshot + pixel diff
- `tests/harness/scichart_reference.html` - SciChart reference chart
- `tests/harness/output/` - Screenshots and diff images

## Build & Test

```bash
# Start test servers (run once per session):
(cd tests/harness && python -m http.server 9080 &)
(cd src/flutter/flet_superplot/build/web && python -m http.server 9081 &)

# Rebuild Flutter web after changes:
cd src/flutter/flet_superplot && flutter build web --release

# Run visual comparison:
python tests/harness/compare.py
```

## Performance Testing

To test with large datasets, modify `main.dart` to generate more points:
```dart
// Change from 1000 to test scaling:
static const int testPoints = 100000;
```

Measure frame time in Flutter DevTools or add performance markers.

## Literature References

- **LTTB**: Steinarsson 2013 MSc thesis - visual-preserving downsampling
- **M4**: VLDB 2014 - "error-free visualizations" for time series
- **MinMaxLTTB**: github.com/predict-idlab/MinMaxLTTB - 30x speedup

## Architecture Notes

- Data transmitted as base64-encoded interleaved Float64 pairs (Python → Flutter)
- CustomPainter for GPU-accelerated rendering via Impeller/Skia
- API mirrors SciChart: SuperPlot ↔ SciChartSurface, NumericAxis, FastLineSeries
