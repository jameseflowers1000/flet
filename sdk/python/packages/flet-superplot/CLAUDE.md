# SuperPlot

High-performance native Flutter charting widget. Sole plot backend for Epyx-EDD. Uses SciChart as visual reference oracle for feature development.

## Project Status

### Checkpoint 1: Visual Match (COMPLETE)
- Static chart matching SciChart layout
- Two sine wave test datasets
- Matching axes, grid, colors
- Playwright-based pixel comparison harness

### Checkpoint 2: Performance (COMPLETE)
- LTTB decimation for 100K+ points (2.5ms/frame @ 200K points)
- Dual-layer rendering cache (grid + axes layers cached as ui.Picture)
- Gesture-aware cache invalidation (skip axis label rebuilds during pan/zoom)
- Binary search for visible data range
- LOD via adaptive LTTB target: `(chartWidth × 2).clamp(100, 10000)`

### Checkpoint 3: Interaction (COMPLETE)
- Mouse wheel zoom (axis-aware: X-only on X axis, Y-only on Y axis, both on chart)
- Drag-to-pan (mouse + touch)
- Pinch-to-zoom (touch/trackpad, centered on focal point)
- Trackpad scroll-to-zoom with momentum animation
- Double-tap reset to fit
- Cursor feedback (grab/grabbing)

### Checkpoint 4: Advanced Rendering (COMPLETE)
- 3 series types: FastLineSeries, XyScatterSeries, FastMountainSeries
- 6 point marker shapes: circle, square, triangle, cross, ellipse, none
- Mountain/area series with gradient fills (vertical linear gradient)
- Point markers on line series (overlay)
- Minor grid lines and ticks (5 subdivisions between major ticks)
- Logarithmic axis support (log-space transforms, decade ticks, Nx10^P labels, log zoom/pan)

### Checkpoint 5: Gap Closure vs SciChart (PLANNED)

**Priority 1 — High impact:**

1. **Crosshair + hover tooltips**
   - Hover shows vertical crosshair line + value readout per series
   - Multi-series rollover (vertical line with stacked values)
   - Dart: MouseRegion/Listener for hover events, overlay painter layer
   - This is the single biggest UX gap for data exploration

2. **Legend**
   - Series name + color swatch + toggle visibility on click
   - Position: top-right or configurable
   - Needed as soon as users have 2+ series

3. **Scatter decimation fix**
   - Current: LTTB applied to scatter — wrong algorithm (biases toward outliers, loses density)
   - Fix: spatial binning (grid cells at pixel resolution, 1 representative per cell) or random sampling
   - Threshold: only decimate when visible points > ~10K
   - Must be per-series-type: lines keep LTTB, scatter uses spatial/random

4. **Label format strings**
   - Already parsed in axis_model.dart (`label_format` field) — just not applied during rendering
   - Hook into `_formatNumber` / `_formatLogNumber` in chart_painter.dart

**Priority 2 — Medium impact:**

5. **Step line draw mode**
   - Already parsed (`draw_mode: "step"` in series_model.dart)
   - Add step path generation in `_drawLineSeries` (horizontal-then-vertical segments)

6. **Spline draw mode**
   - Already parsed (`draw_mode: "spline"`)
   - Catmull-Rom or cubic Bezier interpolation between points

7. **DateTime axis**
   - New axis type with smart tick formatting (seconds/minutes/hours/days/months/years)
   - Important for real-world time series data

8. **Rubber band zoom**
   - Drag rectangle to zoom into region
   - Modifier key (e.g., Shift+drag) to differentiate from pan

9. **Annotations**
   - Horizontal/vertical reference lines (e.g., threshold lines)
   - Text annotations at data coordinates
   - Box annotations (highlighted regions)

**Priority 3 — Lower impact:**

10. **OHLC / Candlestick rendering**
    - OhlcDataSeries structure already exists in data.py — needs Dart painter
    - Relevant if financial data visualization is needed

11. **Multiple Y axes**
    - Left + right Y axes with independent ranges
    - Series bound to specific axis

12. **Band series**
    - Two lines with fill between (confidence intervals, error bands)

## Key Files

**Flutter (rendering):**
- `src/flutter/flet_superplot/lib/src/painters/chart_painter.dart` - Main CustomPainter
- `src/flutter/flet_superplot/lib/src/interactive_chart.dart` - Gesture handling
- `src/flutter/flet_superplot/lib/src/superplot_control.dart` - StatefulWidget bridge
- `src/flutter/flet_superplot/lib/src/models/axis_model.dart` - Axis config
- `src/flutter/flet_superplot/lib/src/models/series_model.dart` - Series + DataPoints
- `src/flutter/flet_superplot/lib/main.dart` - Standalone test app

**Python API:**
- `src/flet_superplot/superplot.py` - Main control (`@ft.control("flet_superplot")`)
- `src/flet_superplot/axis.py` - NumericAxis, LogarithmicAxis
- `src/flet_superplot/series.py` - FastLineSeries, XyScatterSeries, FastMountainSeries
- `src/flet_superplot/data.py` - XyDataSeries, OhlcDataSeries with base64 binary encoding

**Test harness:**
- `tests/harness/compare.py` - Playwright screenshot + pixel diff
- `tests/harness/scichart_reference.html` - SciChart v4 CDN reference chart
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

## Architecture Notes

- Data transmitted as base64-encoded interleaved Float64 pairs (Python → Flutter)
- CustomPainter for GPU-accelerated rendering via Impeller/Skia
- API mirrors SciChart: SuperPlot ↔ SciChartSurface, NumericAxis, FastLineSeries
- SciChart and Matplotlib fully removed from production (eplot.py) — SuperPlot is sole backend
- SciChart test oracle retained in tests/harness/ for visual comparison during development

## Literature References

- **LTTB**: Steinarsson 2013 MSc thesis - visual-preserving downsampling
- **M4**: VLDB 2014 - "error-free visualizations" for time series
- **MinMaxLTTB**: github.com/predict-idlab/MinMaxLTTB - 30x speedup
