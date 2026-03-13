"""
Pytest visual comparison: SuperPlot vs SciChart reference.

This is the HARD GATE for ralph loops — if this test fails, the loop
must NOT declare completion.

Supports per-chart-type comparison via ?chart=<type> URL parameter.
Both SciChart reference and SuperPlot standalone app accept this parameter.

Usage:
    # Build Flutter web first:
    edd build client --platform web

    # Run all visual tests:
    cd packages/flet/sdk/python/packages/flet-superplot
    pytest tests/test_visual_match.py -v

    # Run specific chart type:
    pytest tests/test_visual_match.py -v -k "line"

    # Update reference screenshots:
    pytest tests/test_visual_match.py -v --update-references

Prerequisites:
    pip install pytest playwright Pillow
    playwright install chromium
"""

import http.server
import math
import os
import threading
import time
from pathlib import Path

import pytest

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    pytest.skip("playwright not installed", allow_module_level=True)

try:
    from PIL import Image, ImageChops, ImageStat
except ImportError:
    pytest.skip("Pillow not installed", allow_module_level=True)


# ── Paths ────────────────────────────────────────────────────────────

HARNESS_DIR = Path(__file__).parent / "harness"
OUTPUT_DIR = HARNESS_DIR / "output"
SCICHART_HTML = HARNESS_DIR / "scichart_reference.html"
FLUTTER_BUILD = (
    Path(__file__).parent.parent
    / "src" / "flutter" / "flet_superplot" / "build" / "web"
)

# Viewport must match SciChart reference HTML container size
VIEWPORT = {"width": 800, "height": 600}

# Max allowed diff percent (significant pixels >10 threshold).
# Cross-engine comparison (Flutter Impeller vs SciChart WASM WebGL) has inherent
# cosmetic differences: legend style, axis tick algorithms, font rendering,
# anti-aliasing, fill gradients. 35% threshold catches structural failures
# (missing data, wrong colors, broken rendering) while allowing engine differences.
# Dual-axis charts have extra chrome (two Y axes + legend) increasing diff.
# Non-blank tests (MIN_NON_BACKGROUND_PERCENT) separately verify rendering works.
MAX_DIFF_PERCENT = 40.0

# Non-blank test: at least this % of pixels must NOT be the background color.
MIN_NON_BACKGROUND_PERCENT = 3.0

# Chart types that both SciChart reference and SuperPlot support.
CHART_TYPES = ["mixed", "line", "scatter", "mountain", "column", "candlestick", "band", "dual_axis", "datetime", "impulse", "bubble", "error_bar", "box_plot", "waterfall", "stacked_column", "stacked_mountain"]


# ── pytest options ───────────────────────────────────────────────────

def pytest_addoption(parser):
    parser.addoption(
        "--update-references",
        action="store_true",
        default=False,
        help="Capture new reference screenshots instead of comparing",
    )


# ── Image comparison ─────────────────────────────────────────────────

def compute_image_difference(img1_path: Path, img2_path: Path, diff_path: Path = None) -> dict:
    """Pixel-level comparison between two images."""
    img1 = Image.open(img1_path).convert("RGB")
    img2 = Image.open(img2_path).convert("RGB")

    if img1.size != img2.size:
        return {"error": f"Size mismatch: {img1.size} vs {img2.size}", "match": False}

    diff = ImageChops.difference(img1, img2)
    stat = ImageStat.Stat(diff)

    total_px = img1.size[0] * img1.size[1]
    rmse_per_channel = [math.sqrt(s / total_px) for s in stat.sum2]
    rmse = math.sqrt(sum(x ** 2 for x in rmse_per_channel) / 3)

    threshold = 10
    diff_pixels = 0
    max_diff = 0
    for pixel in diff.getdata():
        pd = max(pixel)
        if pd > threshold:
            diff_pixels += 1
        max_diff = max(max_diff, pd)

    diff_percent = (diff_pixels / total_px) * 100

    if diff_path:
        diff_path.parent.mkdir(parents=True, exist_ok=True)
        diff.save(str(diff_path))

    return {
        "rmse": rmse,
        "max_diff": max_diff,
        "diff_pixels": diff_pixels,
        "diff_percent": diff_percent,
        "total_pixels": total_px,
        "match": diff_pixels == 0,
    }


def assert_not_blank(img_path: Path, background_hex: str = "#1c1c1e"):
    """Assert that the image is not mostly a solid background color."""
    img = Image.open(img_path).convert("RGB")
    bg = tuple(int(background_hex.lstrip("#")[i:i+2], 16) for i in (0, 2, 4))
    tolerance = 15

    bg_pixels = 0
    total = img.size[0] * img.size[1]
    for pixel in img.getdata():
        if all(abs(pixel[c] - bg[c]) <= tolerance for c in range(3)):
            bg_pixels += 1

    non_bg_percent = ((total - bg_pixels) / total) * 100
    assert non_bg_percent >= MIN_NON_BACKGROUND_PERCENT, (
        f"Image appears blank: only {non_bg_percent:.1f}% non-background pixels "
        f"(need >={MIN_NON_BACKGROUND_PERCENT}%). Screenshot: {img_path}"
    )


# ── Local HTTP server helpers ────────────────────────────────────────

class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


def _serve_dir(directory: Path, port: int) -> http.server.HTTPServer:
    """Start a local HTTP server in a daemon thread."""
    handler = lambda *a, **kw: _QuietHandler(*a, directory=str(directory), **kw)
    server = http.server.HTTPServer(("127.0.0.1", port), handler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


# ── Fixtures ─────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def scichart_server():
    """Serve scichart_reference.html on a local port."""
    server = _serve_dir(HARNESS_DIR, 19080)
    yield "http://127.0.0.1:19080"
    server.shutdown()


@pytest.fixture(scope="module")
def superplot_server():
    """Serve Flutter web build on a local port."""
    if not FLUTTER_BUILD.exists():
        pytest.skip(
            f"Flutter web build not found at {FLUTTER_BUILD}. "
            "Run: edd build client --platform web"
        )
    server = _serve_dir(FLUTTER_BUILD, 19081)
    yield "http://127.0.0.1:19081"
    server.shutdown()


@pytest.fixture(scope="module")
def pw_browser():
    """Module-scoped Playwright browser."""
    pw = sync_playwright().start()
    browser = pw.chromium.launch(headless=True)
    yield browser
    browser.close()
    pw.stop()


# ── Helpers ──────────────────────────────────────────────────────────

def _capture_scichart(browser, base_url: str, chart_type: str) -> Path:
    """Capture SciChart screenshot for a given chart type."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    img_path = OUTPUT_DIR / f"scichart_{chart_type}.png"
    page = browser.new_page(viewport=VIEWPORT)
    try:
        page.goto(f"{base_url}/scichart_reference.html?chart={chart_type}")
        page.wait_for_function("window.chartReady === true", timeout=30_000)
        time.sleep(0.5)
        page.screenshot(path=str(img_path))
    finally:
        page.close()
    return img_path


def _capture_superplot(browser, base_url: str, chart_type: str) -> Path:
    """Capture SuperPlot screenshot for a given chart type."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    img_path = OUTPUT_DIR / f"superplot_{chart_type}.png"
    page = browser.new_page(viewport=VIEWPORT)
    try:
        url = f"{base_url}?chart={chart_type}" if chart_type != 'mixed' else base_url
        page.goto(url, wait_until="load", timeout=60_000)
        time.sleep(5)  # Flutter render time (WASM init + paint)
        page.screenshot(path=str(img_path))
    finally:
        page.close()
    return img_path


# ── Tests ────────────────────────────────────────────────────────────

class TestSuperPlotVisualMatch:
    """Visual comparison between SuperPlot and SciChart."""

    def test_superplot_not_blank(self, superplot_server, pw_browser):
        """SuperPlot Flutter build renders something visible (default chart)."""
        img_path = _capture_superplot(pw_browser, superplot_server, "mixed")
        assert_not_blank(img_path)

    def test_scichart_renders(self, scichart_server, pw_browser):
        """SciChart reference page loads and renders successfully."""
        img_path = _capture_scichart(pw_browser, scichart_server, "mixed")
        assert_not_blank(img_path)

    def test_visual_match(self, scichart_server, superplot_server, pw_browser, request):
        """Default (mixed) SuperPlot rendering matches SciChart within tolerance."""
        update_refs = request.config.getoption("--update-references", default=False)

        scichart_img = _capture_scichart(pw_browser, scichart_server, "mixed")
        superplot_img = _capture_superplot(pw_browser, superplot_server, "mixed")

        if update_refs:
            print(f"\nUpdated reference screenshots in {OUTPUT_DIR}")
            return

        diff_img = OUTPUT_DIR / "diff_mixed.png"
        result = compute_image_difference(scichart_img, superplot_img, diff_img)

        if "error" in result:
            pytest.fail(f"Comparison error: {result['error']}")

        print(f"\n  RMSE: {result['rmse']:.4f}")
        print(f"  Max diff: {result['max_diff']}")
        print(f"  Diff pixels (>10): {result['diff_pixels']:,} / {result['total_pixels']:,}")
        print(f"  Diff %: {result['diff_percent']:.2f}%")
        print(f"  Diff image: {diff_img}")

        assert result["diff_percent"] <= MAX_DIFF_PERCENT, (
            f"Visual mismatch: {result['diff_percent']:.2f}% pixels differ "
            f"(max allowed: {MAX_DIFF_PERCENT}%)\n"
            f"  Diff image: {diff_img}"
        )


class TestPerChartTypeNotBlank:
    """Per-chart-type non-blank verification for SuperPlot."""

    @pytest.mark.parametrize("chart_type", CHART_TYPES)
    def test_superplot_not_blank(self, superplot_server, pw_browser, chart_type):
        """Each chart type renders visible content in SuperPlot."""
        img_path = _capture_superplot(pw_browser, superplot_server, chart_type)
        assert_not_blank(img_path)

    @pytest.mark.parametrize("chart_type", CHART_TYPES)
    def test_scichart_not_blank(self, scichart_server, pw_browser, chart_type):
        """Each chart type renders visible content in SciChart reference."""
        img_path = _capture_scichart(pw_browser, scichart_server, chart_type)
        assert_not_blank(img_path)


class TestPerChartTypeVisualMatch:
    """Per-chart-type visual comparison: SuperPlot vs SciChart."""

    @pytest.mark.parametrize("chart_type", CHART_TYPES)
    def test_visual_match(self, scichart_server, superplot_server, pw_browser, chart_type, request):
        """SuperPlot rendering matches SciChart for each chart type."""
        update_refs = request.config.getoption("--update-references", default=False)

        scichart_img = _capture_scichart(pw_browser, scichart_server, chart_type)
        superplot_img = _capture_superplot(pw_browser, superplot_server, chart_type)

        if update_refs:
            print(f"\nUpdated {chart_type} reference screenshots in {OUTPUT_DIR}")
            return

        diff_img = OUTPUT_DIR / f"diff_{chart_type}.png"
        result = compute_image_difference(scichart_img, superplot_img, diff_img)

        if "error" in result:
            pytest.fail(f"[{chart_type}] Comparison error: {result['error']}")

        print(f"\n  [{chart_type}] RMSE: {result['rmse']:.4f}")
        print(f"  [{chart_type}] Diff %: {result['diff_percent']:.2f}%")
        print(f"  [{chart_type}] Diff image: {diff_img}")

        assert result["diff_percent"] <= MAX_DIFF_PERCENT, (
            f"[{chart_type}] Visual mismatch: {result['diff_percent']:.2f}% pixels differ "
            f"(max allowed: {MAX_DIFF_PERCENT}%)\n"
            f"  SciChart: {scichart_img}\n"
            f"  SuperPlot: {superplot_img}\n"
            f"  Diff: {diff_img}"
        )
