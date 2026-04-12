"""
Gallery doclet content — descriptions, sample prompts, and code for each chart type.

Used by the Gallery ETab to seed chart type information.
"""

CHART_GALLERY = [
    {
        "chart_type": "line",
        "description": "Time series plot connecting data points with lines. Supports linear, step, and spline interpolation.",
        "prompt": "Create a line chart showing temperature over the past 24 hours",
        "spec_code": (
            'def render():\n'
            '    chart.line("x", "y", color="#4083FF", name="Temperature")\n'
            '    chart.axis("x0", title="Hour")\n'
            '    chart.axis("y0", title="°C")\n'
            '\n'
            'x = list(range(24))\n'
            'y = [20 + 5*math.sin(h/3.8) + random.gauss(0,1) for h in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "line_step",
        "description": "Step line for discrete state transitions. Horizontal-then-vertical segments.",
        "prompt": "Show server status changes as a step chart",
        "spec_code": (
            'def render():\n'
            '    chart.line("x", "y", color="#26A69A", draw_mode="step", name="Status")\n'
            '\n'
            'x = list(range(20))\n'
            'y = [random.choice([0, 1, 2]) for _ in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "line_spline",
        "description": "Smooth spline interpolation between data points using Catmull-Rom curves.",
        "prompt": "Plot a smooth curve through monthly sales data",
        "spec_code": (
            'def render():\n'
            '    chart.line("x", "y", color="#FF6347", draw_mode="spline", name="Sales")\n'
            '\n'
            'x = list(range(12))\n'
            'y = [100 + 50*math.sin(m/1.9) + random.gauss(0,10) for m in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "scatter",
        "description": "Scatter plot showing correlation between two variables. Supports multiple marker shapes.",
        "prompt": "Create a scatter plot of height vs weight",
        "spec_code": (
            'def render():\n'
            '    chart.scatter("x", "y", color="#4083FF", marker="circle", name="Subjects")\n'
            '\n'
            'x = [160+random.gauss(0,10) for _ in range(100)]\n'
            'y = [0.6*xi + random.gauss(0,8) for xi in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "mountain",
        "description": "Area chart with gradient fill below the line. Good for cumulative distributions.",
        "prompt": "Show network traffic as a filled area chart",
        "spec_code": (
            'def render():\n'
            '    chart.mountain("x", "y", color="#4083FF", fill_color="#4083FF55", name="Traffic")\n'
            '\n'
            'x = list(range(100))\n'
            'y = [50 + 30*math.sin(i/15) + random.gauss(0,5) for i in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "column",
        "description": "Vertical bar chart for categorical comparison. Supports positive and negative values.",
        "prompt": "Compare quarterly revenue across regions",
        "spec_code": (
            'def render():\n'
            '    chart.column("x", "y", fill_color="#4083FF", name="Revenue")\n'
            '    chart.axis("x0", title="Quarter")\n'
            '\n'
            'x = list(range(4))\n'
            'y = [random.randint(50, 200) for _ in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "stacked_column",
        "description": "Stacked column chart showing part-to-whole breakdown per category.",
        "prompt": "Show revenue breakdown by product line per quarter",
        "spec_code": (
            'def render():\n'
            '    chart.column("x", "y1", fill_color="#4083FF", name="Product A", stack_group="g1")\n'
            '    chart.column("x", "y2", fill_color="#26A69A", name="Product B", stack_group="g1")\n'
            '    chart.column("x", "y3", fill_color="#FF6347", name="Product C", stack_group="g1")\n'
            '\n'
            'x = list(range(4))\n'
            'y1 = [random.randint(30,80) for _ in x]\n'
            'y2 = [random.randint(20,60) for _ in x]\n'
            'y3 = [random.randint(10,40) for _ in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "candlestick",
        "description": "OHLC candlestick chart for financial price data. Green=up, red=down.",
        "prompt": "Create a candlestick chart from stock price data",
        "spec_code": (
            'def render():\n'
            '    chart.candlestick("x", "open", "high", "low", "close")\n'
            '    chart.axis("y0", title="Price ($)")\n'
            '\n'
            'x = list(range(50))\n'
            'o_vals, h_vals, l_vals, c_vals = [], [], [], []\n'
            'price = 100\n'
            'for i in x:\n'
            '    o = price; c = o + random.gauss(0,3)\n'
            '    h = max(o,c) + abs(random.gauss(0,1))\n'
            '    l = min(o,c) - abs(random.gauss(0,1))\n'
            '    o_vals.append(o); h_vals.append(h); l_vals.append(l); c_vals.append(c)\n'
            '    price = c\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "band",
        "description": "Band/ribbon between two lines showing confidence intervals or prediction bounds.",
        "prompt": "Show model prediction with confidence interval",
        "spec_code": (
            'def render():\n'
            '    chart.band("x", "y_hi", "y_lo", fill_color="#2196F330", border_color="#2196F3")\n'
            '\n'
            'x = list(range(100))\n'
            'y_mid = [50+20*math.sin(i/15) for i in x]\n'
            'y_hi = [y+5+abs(random.gauss(0,1)) for y in y_mid]\n'
            'y_lo = [y-5-abs(random.gauss(0,1)) for y in y_mid]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "bubble",
        "description": "Scatter with variable-radius markers encoding a third dimension.",
        "prompt": "Plot countries by GDP vs life expectancy, sized by population",
        "spec_code": (
            'def render():\n'
            '    chart.bubble("x", "y", "size", color="#4083FF", name="Countries")\n'
            '\n'
            'x = [random.uniform(1000,50000) for _ in range(30)]\n'
            'y = [60+random.gauss(0,10) for _ in x]\n'
            'size = [random.uniform(1,100) for _ in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "error_bar",
        "description": "Data points with error whiskers showing measurement uncertainty.",
        "prompt": "Show experimental measurements with error bars",
        "spec_code": (
            'def render():\n'
            '    chart.error_bar("x", "y", "err", "err", color="#4083FF")\n'
            '\n'
            'x = list(range(10))\n'
            'y = [50+10*math.sin(i) for i in x]\n'
            'err = [2+random.uniform(0,3) for _ in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "impulse",
        "description": "Vertical stems from baseline to data points. Good for discrete signal visualization.",
        "prompt": "Show frequency spectrum as impulse/stem chart",
        "spec_code": (
            'def render():\n'
            '    chart.impulse("x", "y", color="#4083FF", name="Amplitude")\n'
            '\n'
            'x = list(range(30))\n'
            'y = [abs(random.gauss(0,20)) for _ in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "box_plot",
        "description": "Statistical summary showing quartiles, median, and whiskers per group.",
        "prompt": "Compare test score distributions across classes",
        "spec_code": (
            'def render():\n'
            '    chart.box_plot("x", "min", "q1", "median", "q3", "max")\n'
            '\n'
            'x = list(range(5))\n'
            'mins, q1s, meds, q3s, maxs = [], [], [], [], []\n'
            'for i in x:\n'
            '    data = sorted([random.gauss(70,15) for _ in range(30)])\n'
            '    mins.append(data[0]); q1s.append(data[7]); meds.append(data[15])\n'
            '    q3s.append(data[22]); maxs.append(data[29])\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "waterfall",
        "description": "Running total chart showing sequential positive/negative contributions.",
        "prompt": "Show monthly profit/loss waterfall",
        "spec_code": (
            'def render():\n'
            '    chart.waterfall("x", "y", up_color="#26A69A", down_color="#EF5350")\n'
            '\n'
            'x = list(range(8))\n'
            'y = [20, 15, -8, 12, -5, 25, -10, 8]\n'
            '\n'
            '{"render": render}'
        ),
    },
    {
        "chart_type": "dual_axis",
        "description": "Two Y axes (left + right) for overlaying series with different scales.",
        "prompt": "Show temperature on left axis and humidity on right axis",
        "spec_code": (
            'def render():\n'
            '    chart.line("x", "temp", color="#4083FF", y_axis="y0", name="Temperature")\n'
            '    chart.column("x", "humid", fill_color="#26A69A80", y_axis="y1", name="Humidity")\n'
            '    chart.axis("y0", title="°C")\n'
            '    chart.axis("y1", title="%", align="left")\n'
            '\n'
            'x = list(range(24))\n'
            'temp = [20+5*math.sin(h/3.8) for h in x]\n'
            'humid = [60+20*math.cos(h/4) for h in x]\n'
            '\n'
            '{"render": render}'
        ),
    },
]
