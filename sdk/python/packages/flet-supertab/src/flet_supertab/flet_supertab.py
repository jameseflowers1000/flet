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

    # Styling
    header_bg_color: Optional[str] = field(default=None, metadata={"data_field": "header_bg_color"})
    header_text_color: Optional[str] = field(default=None, metadata={"data_field": "header_text_color"})
    grid_line_color: Optional[str] = field(default=None, metadata={"data_field": "grid_line_color"})

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
