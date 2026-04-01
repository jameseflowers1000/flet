// EpyxGridSource — Data model for EpyxGrid.
// Parses control properties (columns, rows, styles) into a format
// the grid widget can render efficiently.
//
// Reuses formatting logic from flet_supertab_source.dart where possible.

import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

/// Parsed grid data source. Created from Flet control properties.
class EpyxGridSource {
  // -- Column metadata --
  final List<Map<String, dynamic>> columns;
  final List<String> columnNames;
  final List<String> columnLabels;
  final List<String> columnDtypes;
  final List<double> _columnWidths;

  // -- Row data (display-formatted strings) --
  final List<List<Object?>> rows;

  // -- Per-cell styles --
  final List<List<Map<String, String>?>> cellStyles;

  // -- Styling properties (ST1-ST18) --
  final Color headerBgColor;
  final Color headerTextColor;
  final Color gridLineColor;
  final Color cellTextColor;
  final Color cellBgColor;
  final Color alternateRowColor;
  final Color selectionColor;
  final Color currentCellBorderColor;
  final String? fontFamily;
  final double cellFontSize;
  final double headerFontSize;
  final double cellPaddingH;
  final double cellPaddingV;
  final double gridLineWidth;
  final double currentCellBorderWidth;
  final double rowHeight;
  final double headerRowHeight;

  EpyxGridSource({
    required this.columns,
    required this.columnNames,
    required this.columnLabels,
    required this.columnDtypes,
    required List<double> columnWidths,
    required this.rows,
    this.cellStyles = const [],
    this.headerBgColor = const Color(0xFF2D2D30),
    this.headerTextColor = Colors.white,
    this.gridLineColor = const Color(0xFF3E3E42),
    this.cellTextColor = Colors.transparent,
    this.cellBgColor = Colors.transparent,
    this.alternateRowColor = Colors.transparent,
    this.selectionColor = const Color(0x262196F3), // blue@15%
    this.currentCellBorderColor = Colors.blue,
    this.fontFamily,
    this.cellFontSize = 13.0,
    this.headerFontSize = 13.0,
    this.cellPaddingH = 12.0,
    this.cellPaddingV = 4.0,
    this.gridLineWidth = 1.0,
    this.currentCellBorderWidth = 2.0,
    this.rowHeight = 36.0,
    this.headerRowHeight = 40.0,
  }) : _columnWidths = columnWidths;

  /// Factory: parse from a Flet Control's properties.
  factory EpyxGridSource.fromControl(Control control, BuildContext? ctx) {
    // Parse JSON properties
    final colsJson = control.getString("columns");
    final rowsJson = control.getString("rows");

    final cols = colsJson != null && colsJson.isNotEmpty
        ? (jsonDecode(colsJson) as List)
            .map<Map<String, dynamic>>((c) => Map<String, dynamic>.from(c as Map))
            .toList()
        : <Map<String, dynamic>>[];

    final parsedRows = rowsJson != null && rowsJson.isNotEmpty
        ? (jsonDecode(rowsJson) as List)
            .map<List<Object?>>((r) => (r as List).cast<Object?>())
            .toList()
        : <List<Object?>>[];

    final names = cols.map<String>((c) => c["name"] as String).toList();
    final labels = cols
        .map<String>((c) => (c["label"] as String?) ?? c["name"] as String)
        .toList();
    final dtypes =
        cols.map<String>((c) => (c["dtype"] as String?) ?? "str").toList();

    // Column widths: default 120px, last column fills
    final widths = List<double>.generate(
        cols.length, (i) => 120.0); // will be adjusted by lastColumnFill

    // Cell styles
    final cellStylesJson = control.getString("cell_styles");
    List<List<Map<String, String>?>> styles = [];
    if (cellStylesJson != null && cellStylesJson.isNotEmpty) {
      final parsed = jsonDecode(cellStylesJson) as List;
      styles = parsed.map<List<Map<String, String>?>>((row) {
        return (row as List).map<Map<String, String>?>((cell) {
          if (cell == null) return null;
          return Map<String, String>.from(cell as Map);
        }).toList();
      }).toList();
    }

    // Color helper
    Color color(String prop, Color fallback) {
      return control.getColor(prop, ctx, fallback) ?? fallback;
    }

    return EpyxGridSource(
      columns: cols,
      columnNames: names,
      columnLabels: labels,
      columnDtypes: dtypes,
      columnWidths: widths,
      rows: parsedRows,
      cellStyles: styles,
      headerBgColor: color("header_bg_color", const Color(0xFF2D2D30)),
      headerTextColor: color("header_text_color", Colors.white),
      gridLineColor: color("grid_line_color", const Color(0xFF3E3E42)),
      cellTextColor: color("cell_text_color", Colors.transparent),
      cellBgColor: color("cell_bg_color", Colors.transparent),
      alternateRowColor: color("alternate_row_color", Colors.transparent),
      selectionColor: color("selection_color", const Color(0x262196F3)),
      currentCellBorderColor: color("current_cell_border_color", Colors.blue),
      fontFamily: control.getString("font_family"),
      cellFontSize: control.getDouble("cell_font_size", 13.0) ?? 13.0,
      headerFontSize: control.getDouble("header_font_size", 13.0) ?? 13.0,
      cellPaddingH:
          control.getDouble("cell_padding_horizontal", 12.0) ?? 12.0,
      cellPaddingV: control.getDouble("cell_padding_vertical", 4.0) ?? 4.0,
      gridLineWidth: control.getDouble("grid_line_width", 1.0) ?? 1.0,
      currentCellBorderWidth:
          control.getDouble("current_cell_border_width", 2.0) ?? 2.0,
      rowHeight: control.getDouble("row_height", 36.0) ?? 36.0,
      headerRowHeight:
          control.getDouble("header_row_height", 40.0) ?? 40.0,
    );
  }

  // ── Accessors ──────────────────────────────────────────────────

  int get rowCount => rows.length;
  int get columnCount => columns.length;

  String columnName(int i) => columnNames[i];
  String columnLabel(int i) => columnLabels[i];

  double columnWidth(int i) {
    if (i < _columnWidths.length) return _columnWidths[i];
    return 120.0;
  }

  double get totalColumnsWidth {
    double total = 0;
    for (final w in _columnWidths) {
      total += w;
    }
    return total;
  }

  bool isNumericColumn(int i) {
    if (i >= columnDtypes.length) return false;
    final dt = columnDtypes[i];
    return dt == "int" || dt == "float";
  }

  /// Estimate how many rows fit in the viewport.
  int get visibleRowEstimate => rowHeight > 0 ? (600 / rowHeight).ceil() : 20;

  /// Get the display text for a cell.
  String cellText(int row, int col) {
    if (row >= rows.length) return "";
    final r = rows[row];
    if (col >= r.length) return "";
    return r[col]?.toString() ?? "";
  }

  /// Get per-cell style override (or null).
  Map<String, String>? cellStyle(int row, int col) {
    if (row >= cellStyles.length) return null;
    final r = cellStyles[row];
    if (col >= r.length) return null;
    return r[col];
  }

  /// Row background color considering alternate rows and selection.
  Color? rowBackground(int rowIndex, bool isSelected) {
    if (isSelected) return selectionColor;
    if (alternateRowColor != Colors.transparent && rowIndex.isOdd) {
      return alternateRowColor;
    }
    if (cellBgColor != Colors.transparent) return cellBgColor;
    return null;
  }
}
