#!/usr/bin/env python3
"""
Playwright-based visual comparison between SciChart and SuperPlot.

This script:
1. Captures a screenshot of SciChart reference
2. Captures a screenshot of SuperPlot (Flutter web)
3. Computes pixel-level difference
4. Reports match/mismatch with deviation metrics

Usage:
    # First, serve the test files:
    # python -m http.server 8080
    
    # Then run comparison:
    python compare.py
"""

import asyncio
import math
from pathlib import Path
from typing import Tuple
import struct

# Will use playwright for browser automation
try:
    from playwright.async_api import async_playwright
except ImportError:
    print("Please install playwright: pip install playwright && playwright install chromium")
    exit(1)

# Will use PIL for image comparison
try:
    from PIL import Image, ImageChops, ImageStat
except ImportError:
    print("Please install Pillow: pip install Pillow")
    exit(1)


# Test configuration - must match scichart_reference.html
TEST_CONFIG = {
    "series1": {
        "points": 1000,
        "color": "#4083ff",
        "frequency": 2,
        "amplitude": 50,
        "offset": 50,
    },
    "series2": {
        "points": 1000,
        "color": "#ff6347",
        "frequency": 5,
        "amplitude": 30,
        "offset": 50,
    },
    "x_range": {"min": 0, "max": 10},
    "y_range": {"min": 0, "max": 100},
}


def generate_sine_wave(config: dict, x_min: float, x_max: float) -> Tuple[list, list]:
    """Generate sine wave data matching the JS implementation."""
    x_values = []
    y_values = []
    step = (x_max - x_min) / (config["points"] - 1)
    
    for i in range(config["points"]):
        x = x_min + i * step
        y = config["offset"] + config["amplitude"] * math.sin(
            2 * math.pi * config["frequency"] * x / (x_max - x_min)
        )
        x_values.append(x)
        y_values.append(y)
    
    return x_values, y_values


def compute_image_difference(img1_path: Path, img2_path: Path) -> dict:
    """
    Compute difference metrics between two images.
    
    Returns:
        dict with:
            - rmse: Root Mean Square Error
            - max_diff: Maximum pixel difference
            - diff_pixels: Number of different pixels
            - diff_percent: Percentage of different pixels
            - match: True if images are identical
    """
    img1 = Image.open(img1_path).convert("RGB")
    img2 = Image.open(img2_path).convert("RGB")
    
    # Ensure same size
    if img1.size != img2.size:
        return {
            "error": f"Size mismatch: {img1.size} vs {img2.size}",
            "match": False,
        }
    
    # Compute difference
    diff = ImageChops.difference(img1, img2)
    
    # Statistics
    stat = ImageStat.Stat(diff)
    
    # RMSE per channel
    rmse_per_channel = [math.sqrt(sum_sq / (img1.size[0] * img1.size[1])) 
                        for sum_sq in stat.sum2]
    rmse = math.sqrt(sum(x**2 for x in rmse_per_channel) / 3)
    
    # Count different pixels (with threshold to filter anti-aliasing noise)
    threshold = 10  # Ignore sub-pixel rendering differences between engines
    diff_pixels = 0
    diff_pixels_exact = 0
    max_diff = 0
    for pixel in diff.getdata():
        pixel_diff = max(pixel)
        if pixel_diff > 0:
            diff_pixels_exact += 1
        if pixel_diff > threshold:
            diff_pixels += 1
        max_diff = max(max_diff, pixel_diff)

    total_pixels = img1.size[0] * img1.size[1]
    diff_percent = (diff_pixels / total_pixels) * 100
    diff_percent_exact = (diff_pixels_exact / total_pixels) * 100

    # Save diff image (amplified for visibility)
    diff_path = img1_path.parent / "diff.png"
    diff.save(diff_path)

    return {
        "rmse": rmse,
        "max_diff": max_diff,
        "diff_pixels": diff_pixels,
        "diff_pixels_exact": diff_pixels_exact,
        "diff_percent": diff_percent,
        "diff_percent_exact": diff_percent_exact,
        "total_pixels": total_pixels,
        "match": diff_pixels == 0,
        "diff_image": str(diff_path),
    }


async def capture_scichart(output_path: Path) -> bool:
    """Capture screenshot from SciChart reference page."""
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": 800, "height": 600})
        
        # Load the SciChart reference page
        await page.goto("http://localhost:9080/scichart_reference.html")
        
        # Wait for chart to be ready
        await page.wait_for_function("window.chartReady === true", timeout=30000)
        
        # Small delay for rendering to complete
        await asyncio.sleep(0.5)
        
        # Capture full page screenshot
        await page.screenshot(path=str(output_path))
        print(f"✓ SciChart screenshot saved to {output_path}")
        await browser.close()
        return True


async def capture_superplot(output_path: Path, flutter_url: str) -> bool:
    """Capture screenshot from SuperPlot Flutter web build."""
    try:
        async with async_playwright() as p:
            browser = await p.chromium.launch()
            page = await browser.new_page(viewport={"width": 800, "height": 600})
            
            await page.goto(flutter_url, wait_until="networkidle")
            
            # Give Flutter time to render
            await asyncio.sleep(2.0)
            
            # Capture screenshot
            await page.screenshot(path=str(output_path))
            print(f"✓ SuperPlot screenshot saved to {output_path}")
            
            await browser.close()
            return True
    except Exception as e:
        print(f"✗ Failed to capture SuperPlot: {e}")
        return False


async def run_comparison():
    """Run the full comparison workflow."""
    output_dir = Path(__file__).parent / "output"
    output_dir.mkdir(exist_ok=True)
    
    scichart_img = output_dir / "scichart.png"
    superplot_img = output_dir / "superplot.png"
    
    print("=" * 60)
    print("SuperPlot vs SciChart Visual Comparison")
    print("=" * 60)
    
    # Capture SciChart reference
    print("\n1. Capturing SciChart reference...")
    scichart_ok = await capture_scichart(scichart_img)
    
    if not scichart_ok:
        print("\n✗ Failed to capture SciChart. Make sure the server is running:")
        print("  cd tests/harness && python -m http.server 9080")
        return
    
    # Capture SuperPlot from Flutter web build
    print("\n2. Capturing SuperPlot...")
    superplot_ok = await capture_superplot(superplot_img, "http://localhost:9081")
    
    if not superplot_ok:
        print("\n✗ Failed to capture SuperPlot. Make sure the server is running:")
        print("  cd src/flutter/flet_superplot/build/web && python -m http.server 9081")
        return
    
    # Run comparison
    if scichart_ok and superplot_ok:
        print("\n3. Computing difference...")
        result = compute_image_difference(scichart_img, superplot_img)
        
        print("\n" + "=" * 60)
        print("RESULTS")
        print("=" * 60)
        
        if "error" in result:
            print(f"Error: {result['error']}")
        else:
            print(f"RMSE:              {result['rmse']:.4f}")
            print(f"Max Difference:    {result['max_diff']}")
            print(f"Diff Pixels (>10): {result['diff_pixels']:,} / {result['total_pixels']:,}")
            print(f"Diff % (>10):      {result['diff_percent']:.4f}%")
            print(f"Diff Pixels (any): {result['diff_pixels_exact']:,} / {result['total_pixels']:,}")
            print(f"Diff % (exact):    {result['diff_percent_exact']:.4f}%")
            print(f"Diff Image:        {result['diff_image']}")
            print()

            if result['match']:
                print("✓ PERFECT MATCH - Images are identical!")
            elif result['diff_percent'] < 1.0:
                print("~ CLOSE MATCH - Less than 1% significant pixels differ")
            elif result['diff_percent'] < 5.0:
                print("~ PARTIAL MATCH - Less than 5% significant pixels differ")
            elif result['diff_percent'] < 10.0:
                print("~ NEAR MATCH - Less than 10% significant pixels differ")
            else:
                print("✗ SIGNIFICANT DIFFERENCE - More than 10% significant pixels differ")


def main():
    """Entry point."""
    asyncio.run(run_comparison())


if __name__ == "__main__":
    main()
