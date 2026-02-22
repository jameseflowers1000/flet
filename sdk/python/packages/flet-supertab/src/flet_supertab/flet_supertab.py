from dataclasses import field
import json
from typing import Any, Optional

import flet as ft


@ft.control("flet_supertab")
class SuperTab(ft.LayoutControl):
    """
    Supertab DataGrid-like control powered by Syncfusion under the hood.

    Supports inline cell editing when `editable=True`.
    """

    # JSON-encoded column definitions
    columns: Optional[str] = field(default=None, metadata={"data_field": "columns"})
    # JSON-encoded rows
    rows: Optional[str] = field(default=None, metadata={"data_field": "rows"})
    # Enable inline editing
    editable: bool = False

    # Navigation / selection
    selection_mode: str = "cell"  # "none", "row", "cell"

    # Interaction
    allow_sorting: bool = field(default=False, metadata={"data_field": "allow_sorting"})
    allow_column_resize: bool = field(default=False, metadata={"data_field": "allow_column_resize"})

    # Config properties (synced from ETab)
    show_row_numbers: bool = field(default=False, metadata={"data_field": "show_row_numbers"})
    show_checkbox_column: bool = field(default=False, metadata={"data_field": "show_checkbox_column"})
    frozen_columns_count: int = field(default=0, metadata={"data_field": "frozen_columns_count"})
    row_height: float = field(default=36.0, metadata={"data_field": "row_height"})
    header_row_height: float = field(default=40.0, metadata={"data_field": "header_row_height"})

    # Styling — colors
    header_bg_color: Optional[str] = field(default=None, metadata={"data_field": "header_bg_color"})
    header_text_color: Optional[str] = field(default=None, metadata={"data_field": "header_text_color"})
    grid_line_color: Optional[str] = field(default=None, metadata={"data_field": "grid_line_color"})
    cell_text_color: Optional[str] = field(default=None, metadata={"data_field": "cell_text_color"})
    cell_bg_color: Optional[str] = field(default=None, metadata={"data_field": "cell_bg_color"})
    alternate_row_color: Optional[str] = field(default=None, metadata={"data_field": "alternate_row_color"})
    selection_color: Optional[str] = field(default=None, metadata={"data_field": "selection_color"})
    current_cell_border_color: Optional[str] = field(default=None, metadata={"data_field": "current_cell_border_color"})

    # Styling — fonts
    font_family: Optional[str] = field(default=None, metadata={"data_field": "font_family"})
    cell_font_size: float = field(default=13.0, metadata={"data_field": "cell_font_size"})
    header_font_size: float = field(default=13.0, metadata={"data_field": "header_font_size"})
    header_font_weight: str = field(default="w600", metadata={"data_field": "header_font_weight"})

    # Styling — spacing
    cell_padding_horizontal: float = field(default=12.0, metadata={"data_field": "cell_padding_horizontal"})
    cell_padding_vertical: float = field(default=4.0, metadata={"data_field": "cell_padding_vertical"})
    header_padding_horizontal: float = field(default=12.0, metadata={"data_field": "header_padding_horizontal"})
    header_padding_vertical: float = field(default=8.0, metadata={"data_field": "header_padding_vertical"})
    grid_line_width: float = field(default=1.0, metadata={"data_field": "grid_line_width"})
    current_cell_border_width: float = field(default=2.0, metadata={"data_field": "current_cell_border_width"})

    # Event: called when a cell is edited
    # Event data (in e.data as JSON): {"row_index": int, "column_name": str, "old_value": str, "new_value": str}
    on_cell_edit: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Internal storage for the actual list data
    _columns_data: list[dict[str, Any]] = field(default_factory=list, repr=False, metadata={"skip": True})
    _rows_data: list[list[Any]] = field(default_factory=list, repr=False, metadata={"skip": True})

    def __post_init__(self, ref=None):
        super().__post_init__(ref)
        # If columns/rows were passed as lists, convert to JSON
        if isinstance(self.columns, list):
            self._columns_data = self.columns
            self.columns = json.dumps(self.columns)
        if isinstance(self.rows, list):
            self._rows_data = self.rows
            self.rows = json.dumps(self.rows)

    def set_columns(self, columns: list[dict[str, Any]]):
        self._columns_data = columns
        self.columns = json.dumps(columns)

    def set_rows(self, rows: list[list[Any]]):
        self._rows_data = rows
        self.rows = json.dumps(rows)

    def set_data(self, columns: list[dict[str, Any]], rows: list[list[Any]]):
        """Convenience: set both columns and rows, then update."""
        self.set_columns(columns)
        self.set_rows(rows)
