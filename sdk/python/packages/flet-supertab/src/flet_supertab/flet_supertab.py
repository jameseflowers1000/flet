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

    # ─── Tab-navigation metadata ──────────────────────────────────────────
    # Mirrored from the host ETab Property's tab_group / tab_order /
    # tab_skip by etab.py's _push_tab_meta_to_widget. Consumed by the
    # Dart widget's EpyxFocusable wrapper — the whole grid is one focus
    # stop in the group; cell-level arrow navigation happens once focused.
    tab_group: Optional[int] = field(default=None, metadata={"data_field": "tab_group"})
    tab_order: Optional[int] = field(default=None, metadata={"data_field": "tab_order"})
    tab_skip: bool = field(default=False, metadata={"data_field": "tab_skip"})
    tab_name: str = field(default="", metadata={"data_field": "tab_name"})

    # JSON-encoded column definitions
    columns: Optional[str] = field(default=None, metadata={"data_field": "columns"})
    # JSON-encoded rows
    rows: Optional[str] = field(default=None, metadata={"data_field": "rows"})
    # JSON-encoded raw (unformatted) rows for cell editing
    raw_rows: Optional[str] = field(default=None, metadata={"data_field": "raw_rows"})
    # Enable inline editing
    editable: bool = False

    # Navigation / selection
    selection_mode: str = "cell"  # "none", "row", "cell"

    # Interaction
    allow_sorting: bool = field(default=False, metadata={"data_field": "allow_sorting"})
    allow_column_resize: bool = field(default=False, metadata={"data_field": "allow_column_resize"})
    allow_add_row: bool = field(default=True, metadata={"data_field": "allow_add_row"})
    allow_delete_row: bool = field(default=True, metadata={"data_field": "allow_delete_row"})
    allow_insert_row: bool = field(default=True, metadata={"data_field": "allow_insert_row"})
    allow_override: bool = field(default=True, metadata={"data_field": "allow_override"})

    # Config properties (synced from ETab)
    show_row_numbers: bool = field(default=False, metadata={"data_field": "show_row_numbers"})
    show_checkbox_column: bool = field(default=False, metadata={"data_field": "show_checkbox_column"})
    frozen_columns_count: int = field(default=0, metadata={"data_field": "frozen_columns_count"})
    frozen_rows_count: int = field(default=0, metadata={"data_field": "frozen_rows_count"})
    row_height: float = field(default=36.0, metadata={"data_field": "row_height"})
    # JSON array of per-row heights (overrides row_height when set)
    row_heights: Optional[str] = field(default=None, metadata={"data_field": "row_heights"})
    # Sparse JSON map of row height overrides: {"row_idx": height}
    # Pushed upfront so Dart's extentEstimation is correct for ALL rows.
    row_height_overrides: Optional[str] = field(default=None, metadata={"data_field": "row_height_overrides"})
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

    # Tab header: label, ctype, and status indicators for the header bar
    label: str = field(default="", metadata={"data_field": "label"})
    ctype: str = field(default="", metadata={"data_field": "ctype"})
    sort_indicator: str = field(default="", metadata={"data_field": "sort_indicator"})
    filter_active: bool = field(default=False, metadata={"data_field": "filter_active"})

    # Error message to display as a banner above the grid
    error_message: str = field(default="", metadata={"data_field": "error_message"})

    # JSON array of "row:col_name" strings identifying cells with overrides
    override_cells: Optional[str] = field(default=None, metadata={"data_field": "override_cells"})

    # JSON array of validation errors for red border display
    # Structure: [{"row": int, "col": "name", "msg": "error"}]
    validation_errors: Optional[str] = field(default=None, metadata={"data_field": "validation_errors"})

    # JSON-encoded cell styles for conditional formatting (§9.5)
    # Structure: [[{"bg": "#color", "fg": "#color"} | null, ...], ...]
    cell_styles: Optional[str] = field(default=None, metadata={"data_field": "cell_styles"})

    # Dart-side MicroPython render scripts (§6A)
    render_code: str = field(default="", metadata={"data_field": "render_code"})
    row_render_code: str = field(default="", metadata={"data_field": "row_render_code"})

    # Dart-side MicroPython keyboard handler (§6)
    on_key_code: str = field(default="", metadata={"data_field": "on_key_code"})

    # JSON-encoded summary row values (list of strings in column order) for footer display
    summary_row: str = field(default="", metadata={"data_field": "summary_row"})

    # Event: called when a cell is edited
    # Event data (in e.data as JSON): {"row_index": int, "column_name": str, "old_value": str, "new_value": str}
    on_cell_edit: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Event: called on context menu actions (paste, clear, remove_override)
    # Event data (in e.data as JSON): {"action": str, "row_index": int, "column_name": str, "value": str?}
    on_context_action: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Event: called when checkbox selection changes (only when show_checkbox_column=True)
    # Event data (in e.data as JSON): {"selected_rows": [int, ...]}
    on_checkbox_selection: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Event: LOD page request — fired when Dart scrolls near the end of loaded data
    # Event data (in e.data as JSON): {"offset": int, "limit": int}
    # EScalar analog: same Flet event pattern as on_cell_edit (escalar has no LOD)
    on_page_request: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Event: sort request — fired when user clicks a column header to sort
    # Event data (in e.data as JSON): {"column": str, "ascending": bool}
    on_sort_request: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Event: column resize — fired when user drags a column border
    # Event data (in e.data as JSON): {"column": str, "width": float}
    on_column_resize: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # Event: selection change — fired when the selected cell changes
    # Event data (in e.data as JSON): {"row": int, "col": int, "column_name": str, "end_row": int, "end_col": int}
    on_selection_change: Optional[ft.ControlEventHandler["SuperTab"]] = None

    # JSON list of column names to hide (e.g., '["col_a", "col_b"]')
    hidden_columns: Optional[str] = field(default=None, metadata={"data_field": "hidden_columns"})

    # Total row count for LOD (Dart uses this to size the scrollbar)
    total_rows: int = field(default=0, metadata={"data_field": "total_rows"})

    # Pixel-space LOD metadata (always pushed by _sync_to_control)
    total_height: float = field(default=0.0, metadata={"data_field": "total_height"})
    data_version: int = field(default=0, metadata={"data_field": "data_version"})
    # Atomic page data blob: rows, pixel_offsets, buffer_start, storage_indices,
    # cell_styles, override_cells, token — all in one JSON string.
    page_data: Optional[str] = field(default=None, metadata={"data_field": "page_data"})

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

    def set_raw_rows(self, raw_rows: list[list[Any]]):
        self.raw_rows = json.dumps(raw_rows)

    def set_data(self, columns: list[dict[str, Any]], rows: list[list[Any]]):
        """Convenience: set both columns and rows, then update."""
        self.set_columns(columns)
        self.set_rows(rows)
