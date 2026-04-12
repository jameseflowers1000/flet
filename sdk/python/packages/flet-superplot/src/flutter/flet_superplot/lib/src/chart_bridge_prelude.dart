/// MicroPython prelude that defines the ChartBridge class and a singleton
/// instance `chart` in the global namespace. Registered with
/// MicroPythonService at extension load time.
///
/// The bridge accumulates chart configuration via method calls (chart.line,
/// chart.axis, etc.) and exposes _to_config() to serialize the accumulated
/// state to a dict. Call chart._reset() before each evaluation to clear
/// accumulated state from the previous run.
///
/// Must work in MicroPython (no dataclasses, no typing, no numpy).
const String chartBridgePrelude = '''
class ChartBridge:
    def __init__(self):
        self._reset()

    def _reset(self):
        self._series = []
        self._axes = []
        self._legend = None
        self._annotations = []

    def line(self, x_col, y_col, color="#4083FF", name=None, width=2,
             y_axis="y0", draw_mode="linear", opacity=1.0,
             point_marker=None, tooltip_format=None, color_formula=None,
             dash_pattern=None):
        self._series.append({
            "type": "line", "x_col": x_col, "y_col": y_col,
            "color": color, "name": name, "width": width,
            "y_axis": y_axis, "draw_mode": draw_mode, "opacity": opacity,
            "point_marker": point_marker, "tooltip_format": tooltip_format,
            "color_formula": color_formula, "dash_pattern": dash_pattern,
        })

    def scatter(self, x_col, y_col, color="#FF6600", name=None, size=8,
                marker="circle", y_axis="y0", opacity=1.0, tooltip_format=None,
                color_formula=None):
        self._series.append({
            "type": "scatter", "x_col": x_col, "y_col": y_col,
            "color": color, "name": name, "size": size,
            "marker": marker, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format, "color_formula": color_formula,
        })

    def mountain(self, x_col, y_col, color="#4083FF", fill_color=None,
                 name=None, width=2, y_axis="y0", opacity=1.0,
                 zero_line_y=0.0, tooltip_format=None, stack_group=None):
        self._series.append({
            "type": "mountain", "x_col": x_col, "y_col": y_col,
            "color": color, "fill_color": fill_color, "name": name,
            "width": width, "y_axis": y_axis, "opacity": opacity,
            "zero_line_y": zero_line_y, "tooltip_format": tooltip_format,
            "stack_group": stack_group,
        })

    def column(self, x_col, y_col, fill_color="#4083FF", stroke_color=None,
               bar_width=0.7, name=None, y_axis="y0", opacity=1.0,
               tooltip_format=None, color_formula=None, stack_group=None):
        self._series.append({
            "type": "column", "x_col": x_col, "y_col": y_col,
            "fill_color": fill_color, "stroke_color": stroke_color,
            "bar_width": bar_width, "name": name, "y_axis": y_axis,
            "opacity": opacity, "tooltip_format": tooltip_format,
            "color_formula": color_formula, "stack_group": stack_group,
        })

    def candlestick(self, x_col, open_col, high_col, low_col, close_col,
                    up_color="#26A69A", down_color="#EF5350", wick_color=None,
                    body_width=0.6, name=None, y_axis="y0", opacity=1.0,
                    tooltip_format=None, color_formula=None):
        self._series.append({
            "type": "candlestick", "x_col": x_col,
            "open_col": open_col, "high_col": high_col,
            "low_col": low_col, "close_col": close_col,
            "up_color": up_color, "down_color": down_color,
            "wick_color": wick_color, "body_width": body_width,
            "name": name, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format, "color_formula": color_formula,
        })

    def band(self, x_col, y_high_col, y_low_col, fill_color="#2196F320",
             border_color=None, border_width=1.0, name=None, y_axis="y0",
             opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "band", "x_col": x_col,
            "y_high_col": y_high_col, "y_low_col": y_low_col,
            "fill_color": fill_color, "border_color": border_color,
            "border_width": border_width, "name": name,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def impulse(self, x_col, y_col, color="#4083FF", name=None, width=1.0,
                y_axis="y0", opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "impulse", "x_col": x_col, "y_col": y_col,
            "color": color, "name": name, "width": width,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def bubble(self, x_col, y_col, size_col, color="#4083FF", name=None,
               y_axis="y0", opacity=0.7, tooltip_format=None):
        self._series.append({
            "type": "bubble", "x_col": x_col, "y_col": y_col,
            "size_col": size_col, "color": color, "name": name,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def error_bar(self, x_col, y_col, error_high_col, error_low_col=None,
                  color="#4083FF", name=None, width=1.5, cap_width=6.0,
                  y_axis="y0", opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "error_bar", "x_col": x_col, "y_col": y_col,
            "error_high_col": error_high_col,
            "error_low_col": error_low_col if error_low_col else error_high_col,
            "color": color, "name": name, "width": width,
            "cap_width": cap_width, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def box_plot(self, x_col, min_col, q1_col, median_col, q3_col, max_col,
                 fill_color="#4083FF40", stroke_color="#4083FF",
                 median_color="#FFFFFF", name=None, y_axis="y0",
                 opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "box_plot", "x_col": x_col,
            "min_col": min_col, "q1_col": q1_col,
            "median_col": median_col, "q3_col": q3_col,
            "max_col": max_col, "fill_color": fill_color,
            "stroke_color": stroke_color, "median_color": median_color,
            "name": name, "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def waterfall(self, x_col, y_col, up_color="#26A69A", down_color="#EF5350",
                  total_color="#4083FF", name=None, y_axis="y0",
                  opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "waterfall", "x_col": x_col, "y_col": y_col,
            "up_color": up_color, "down_color": down_color,
            "total_color": total_color, "name": name,
            "y_axis": y_axis, "opacity": opacity,
            "tooltip_format": tooltip_format,
        })

    def histogram(self, y_col, bins=20, color="#4083FF", name=None,
                  y_axis="y0", opacity=1.0, tooltip_format=None):
        self._series.append({
            "type": "histogram", "y_col": y_col, "bins": bins,
            "color": color, "name": name, "y_axis": y_axis,
            "opacity": opacity, "tooltip_format": tooltip_format,
        })

    def axis(self, axis_id, title=None, type="numeric", align="left",
             range_mode="auto", visible_range_min=None, visible_range_max=None,
             log_base=10, label_format=None):
        self._axes.append({
            "id": axis_id, "title": title, "type": type,
            "align": align, "range_mode": range_mode,
            "visible_range_min": visible_range_min,
            "visible_range_max": visible_range_max,
            "log_base": log_base, "label_format": label_format,
        })

    def legend(self, position="top-left", checkboxes=True):
        self._legend = {"position": position, "checkboxes": checkboxes}

    def hline(self, y, color="#FFFF00", label=None, thickness=1.0, opacity=0.8):
        self._annotations.append({
            "type": "horizontal_line", "y": y, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def vline(self, x, color="#FFFF00", label=None, thickness=1.0, opacity=0.8):
        self._annotations.append({
            "type": "vertical_line", "x": x, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def draggable_hline(self, id, y, color="#FFFF00", label=None,
                        thickness=1.5, opacity=0.8):
        self._annotations.append({
            "type": "draggable_hline", "id": id, "y": y, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def draggable_vline(self, id, x, color="#FFFF00", label=None,
                        thickness=1.5, opacity=0.8):
        self._annotations.append({
            "type": "draggable_vline", "id": id, "x": x, "color": color,
            "label": label, "thickness": thickness, "opacity": opacity,
        })

    def _to_config(self):
        config = {
            "series": self._series,
            "axes": self._axes,
            "annotations": self._annotations,
        }
        if self._legend is not None:
            config["legend"] = self._legend
        return config

chart = ChartBridge()
try:
    _epyx_user_preludes['chart'] = chart
except NameError:
    pass
''';
