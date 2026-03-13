"""
Gallery doclet content — descriptions, sample prompts, and code for each chart type.

Used by the Gallery ETab to seed chart type information.
"""

CHART_GALLERY = [
    {
        "chart_type": "line",
        "description": "Time series plot connecting data points with lines. Supports linear, step, and spline interpolation.",
        "prompt": "Create a line chart showing temperature over the past 24 hours",
        "series_code": 'x = list(range(24))\ny = [20 + 5*math.sin(h/3.8) + random.gauss(0,1) for h in x]',
        "plot_code": 'chart.line("x", "y", color="#4083FF", name="Temperature")\nchart.axis("x0", title="Hour")\nchart.axis("y0", title="°C")',
    },
    {
        "chart_type": "line_step",
        "description": "Step line for discrete state transitions. Horizontal-then-vertical segments.",
        "prompt": "Show server status changes as a step chart",
        "series_code": 'x = list(range(20))\ny = [random.choice([0, 1, 2]) for _ in x]',
        "plot_code": 'chart.line("x", "y", color="#26A69A", draw_mode="step", name="Status")',
    },
    {
        "chart_type": "line_spline",
        "description": "Smooth spline interpolation between data points using Catmull-Rom curves.",
        "prompt": "Plot a smooth curve through monthly sales data",
        "series_code": 'x = list(range(12))\ny = [100 + 50*math.sin(m/1.9) + random.gauss(0,10) for m in x]',
        "plot_code": 'chart.line("x", "y", color="#FF6347", draw_mode="spline", name="Sales")',
    },
    {
        "chart_type": "scatter",
        "description": "Scatter plot showing correlation between two variables. Supports multiple marker shapes.",
        "prompt": "Create a scatter plot of height vs weight",
        "series_code": 'x = [160+random.gauss(0,10) for _ in range(100)]\ny = [0.6*xi + random.gauss(0,8) for xi in x]',
        "plot_code": 'chart.scatter("x", "y", color="#4083FF", marker="circle", name="Subjects")',
    },
    {
        "chart_type": "mountain",
        "description": "Area chart with gradient fill below the line. Good for cumulative distributions.",
        "prompt": "Show network traffic as a filled area chart",
        "series_code": 'x = list(range(100))\ny = [50 + 30*math.sin(i/15) + random.gauss(0,5) for i in x]',
        "plot_code": 'chart.mountain("x", "y", color="#4083FF", fill_color="#4083FF55", name="Traffic")',
    },
    {
        "chart_type": "column",
        "description": "Vertical bar chart for categorical comparison. Supports positive and negative values.",
        "prompt": "Compare quarterly revenue across regions",
        "series_code": 'x = list(range(4))\ny = [random.randint(50, 200) for _ in x]',
        "plot_code": 'chart.column("x", "y", fill_color="#4083FF", name="Revenue")\nchart.axis("x0", title="Quarter")',
    },
    {
        "chart_type": "stacked_column",
        "description": "Stacked column chart showing part-to-whole breakdown per category.",
        "prompt": "Show revenue breakdown by product line per quarter",
        "series_code": 'x = list(range(4))\ny1 = [random.randint(30,80) for _ in x]\ny2 = [random.randint(20,60) for _ in x]\ny3 = [random.randint(10,40) for _ in x]',
        "plot_code": 'chart.column("x", "y1", fill_color="#4083FF", name="Product A", stack_group="g1")\nchart.column("x", "y2", fill_color="#26A69A", name="Product B", stack_group="g1")\nchart.column("x", "y3", fill_color="#FF6347", name="Product C", stack_group="g1")',
    },
    {
        "chart_type": "candlestick",
        "description": "OHLC candlestick chart for financial price data. Green=up, red=down.",
        "prompt": "Create a candlestick chart from stock price data",
        "series_code": 'x = list(range(50))\n# Generate OHLC from random walk\nprice = 100\nfor i in x:\n    o = price; c = o + random.gauss(0,3)\n    h = max(o,c) + abs(random.gauss(0,1))\n    l = min(o,c) - abs(random.gauss(0,1))\n    price = c',
        "plot_code": 'chart.candlestick("x", "open", "high", "low", "close")\nchart.axis("y0", title="Price ($)")',
    },
    {
        "chart_type": "band",
        "description": "Band/ribbon between two lines showing confidence intervals or prediction bounds.",
        "prompt": "Show model prediction with confidence interval",
        "series_code": 'x = list(range(100))\ny_mid = [50+20*math.sin(i/15) for i in x]\ny_hi = [y+5+random.gauss(0,1) for y in y_mid]\ny_lo = [y-5-random.gauss(0,1) for y in y_mid]',
        "plot_code": 'chart.band("x", "y_hi", "y_lo", fill_color="#2196F330", border_color="#2196F3")',
    },
    {
        "chart_type": "bubble",
        "description": "Scatter with variable-radius markers encoding a third dimension.",
        "prompt": "Plot countries by GDP vs life expectancy, sized by population",
        "series_code": 'x = [random.uniform(1000,50000) for _ in range(30)]\ny = [60+random.gauss(0,10) for _ in x]\nsize = [random.uniform(1,100) for _ in x]',
        "plot_code": 'chart.bubble("x", "y", "size", color="#4083FF", name="Countries")',
    },
    {
        "chart_type": "error_bar",
        "description": "Data points with error whiskers showing measurement uncertainty.",
        "prompt": "Show experimental measurements with error bars",
        "series_code": 'x = list(range(10))\ny = [50+10*math.sin(i) for i in x]\nerr = [2+random.uniform(0,3) for _ in x]',
        "plot_code": 'chart.error_bar("x", "y", "err", "err", color="#4083FF")',
    },
    {
        "chart_type": "impulse",
        "description": "Vertical stems from baseline to data points. Good for discrete signal visualization.",
        "prompt": "Show frequency spectrum as impulse/stem chart",
        "series_code": 'x = list(range(30))\ny = [abs(random.gauss(0,20)) for _ in x]',
        "plot_code": 'chart.impulse("x", "y", color="#4083FF", name="Amplitude")',
    },
    {
        "chart_type": "box_plot",
        "description": "Statistical summary showing quartiles, median, and whiskers per group.",
        "prompt": "Compare test score distributions across classes",
        "series_code": '# Pre-compute quartiles per group\nx = list(range(5))\nfor i in x:\n    data = sorted([random.gauss(70,15) for _ in range(30)])\n    # min, q1, median, q3, max',
        "plot_code": 'chart.box_plot("x", "min", "q1", "median", "q3", "max")',
    },
    {
        "chart_type": "waterfall",
        "description": "Running total chart showing sequential positive/negative contributions.",
        "prompt": "Show monthly profit/loss waterfall",
        "series_code": 'x = list(range(8))\ny = [20, 15, -8, 12, -5, 25, -10, 8]  # contributions',
        "plot_code": 'chart.waterfall("x", "y", up_color="#26A69A", down_color="#EF5350")',
    },
    {
        "chart_type": "dual_axis",
        "description": "Two Y axes (left + right) for overlaying series with different scales.",
        "prompt": "Show temperature on left axis and humidity on right axis",
        "series_code": 'x = list(range(24))\ntemp = [20+5*math.sin(h/3.8) for h in x]\nhumid = [60+20*math.cos(h/4) for h in x]',
        "plot_code": 'chart.line("x", "temp", color="#4083FF", y_axis="y0", name="Temperature")\nchart.column("x", "humid", fill_color="#26A69A80", y_axis="y1", name="Humidity")\nchart.axis("y0", title="°C")\nchart.axis("y1", title="%", align="left")',
    },
]
