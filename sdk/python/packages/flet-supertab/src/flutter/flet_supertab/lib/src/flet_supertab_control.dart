import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';
import 'package:syncfusion_flutter_core/theme.dart';

import 'flet_supertab_source.dart';

class SuperTabControl extends StatefulWidget {
  final Control control;

  const SuperTabControl({
    super.key,
    required this.control,
  });

  @override
  State<SuperTabControl> createState() => _SuperTabControlState();
}

class _SuperTabControlState extends State<SuperTabControl> {
  late FletDataGridSource _source;
  List<dynamic> _cols = [];
  List<List<Object?>> _dataRows = [];
  List<String> _columnNames = [];

  /// Tracks user-resized column widths (columnName → width).
  /// Columns not in this map use auto-fill sizing.
  final Map<String, double> _columnWidths = {};

  @override
  void initState() {
    super.initState();
    _parseData();
    _buildSource();
  }

  @override
  void didUpdateWidget(covariant SuperTabControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseData();
    _buildSource();
  }

  void _parseData() {
    final colsJson = widget.control.getString("columns");
    final rowsJson = widget.control.getString("rows");

    _cols = colsJson != null && colsJson.isNotEmpty ? jsonDecode(colsJson) : [];
    final rows =
        rowsJson != null && rowsJson.isNotEmpty ? jsonDecode(rowsJson) : [];

    _columnNames =
        _cols.map<String>((c) => (c as Map)["name"] as String).toList();
    _dataRows = (rows as List)
        .map<List<Object?>>((r) => (r as List).cast<Object?>())
        .toList();
  }

  void _buildSource() {
    final showRowNumbers = widget.control.getBool("show_row_numbers", false)!;
    final cellTextColor = _parseColor(widget.control.getString("cell_text_color"));
    final cellBgColor = _parseColor(widget.control.getString("cell_bg_color"));
    final alternateRowColor = _parseColor(widget.control.getString("alternate_row_color"));
    final cellFontSize = widget.control.getDouble("cell_font_size", 13.0)!;
    final fontFamily = widget.control.getString("font_family");
    final cellPadH = widget.control.getDouble("cell_padding_horizontal", 12.0)!;
    final cellPadV = widget.control.getDouble("cell_padding_vertical", 4.0)!;

    _source = FletDataGridSource(
      rows: _dataRows,
      columnNames: _columnNames,
      columnDefs: _cols,
      onCellEdit: _handleCellEdit,
      showRowNumbers: showRowNumbers,
      cellTextColor: cellTextColor,
      cellBgColor: cellBgColor,
      alternateRowColor: alternateRowColor,
      cellFontSize: cellFontSize,
      fontFamily: fontFamily,
      cellPaddingHorizontal: cellPadH,
      cellPaddingVertical: cellPadV,
    );
  }

  void _handleCellEdit(
      int rowIndex, String columnName, Object? oldValue, Object? newValue) {
    final eventData = jsonEncode({
      "row_index": rowIndex,
      "column_name": columnName,
      "old_value": oldValue?.toString(),
      "new_value": newValue?.toString(),
    });
    widget.control.triggerEventWithoutSubscribers("cell_edit", eventData);
  }

  Color _parseColor(String? hex, [Color fallback = Colors.transparent]) {
    if (hex == null || hex.isEmpty) return fallback;
    hex = hex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  FontWeight _parseFontWeight(String? w) {
    switch (w) {
      case "w100": return FontWeight.w100;
      case "w200": return FontWeight.w200;
      case "w300": return FontWeight.w300;
      case "w400": return FontWeight.w400;
      case "w500": return FontWeight.w500;
      case "w600": return FontWeight.w600;
      case "w700": return FontWeight.w700;
      case "w800": return FontWeight.w800;
      case "w900": return FontWeight.w900;
      case "bold": return FontWeight.bold;
      case "normal": return FontWeight.normal;
      default: return FontWeight.w600;
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = widget.control.getBool("editable", false)!;

    // Colors
    final headerBg =
        _parseColor(widget.control.getString("header_bg_color"), const Color(0xFF2D2D30));
    final headerTextColor =
        _parseColor(widget.control.getString("header_text_color"), Colors.white);
    final gridLineColor =
        _parseColor(widget.control.getString("grid_line_color"), const Color(0xFF3E3E42));
    final selectionColor =
        _parseColor(widget.control.getString("selection_color"), Colors.blue.withValues(alpha: 0.15));
    final currentCellBorderColor =
        _parseColor(widget.control.getString("current_cell_border_color"), Colors.blue);

    // Fonts
    final fontFamily = widget.control.getString("font_family");
    final headerFontSize = widget.control.getDouble("header_font_size", 13.0)!;
    final headerFontWeight = _parseFontWeight(widget.control.getString("header_font_weight"));
    final cellFontSize = widget.control.getDouble("cell_font_size", 13.0)!;

    // Spacing
    final headerPadH = widget.control.getDouble("header_padding_horizontal", 12.0)!;
    final headerPadV = widget.control.getDouble("header_padding_vertical", 8.0)!;
    final gridLineWidth = widget.control.getDouble("grid_line_width", 1.0)!;
    final currentCellBorderWidth = widget.control.getDouble("current_cell_border_width", 2.0)!;

    // Selection mode
    final selectionModeStr =
        widget.control.getString("selection_mode") ?? "cell";
    SelectionMode selectionMode;
    GridNavigationMode navMode;
    switch (selectionModeStr) {
      case "row":
        selectionMode = SelectionMode.single;
        navMode = GridNavigationMode.row;
        break;
      case "none":
        selectionMode = SelectionMode.none;
        navMode = GridNavigationMode.row;
        break;
      case "cell":
      default:
        selectionMode = SelectionMode.single;
        navMode = GridNavigationMode.cell;
        break;
    }

    final allowSorting = widget.control.getBool("allow_sorting", false)!;
    final allowColumnResize = widget.control.getBool("allow_column_resize", false)!;

    // Config properties from ETab
    final showRowNumbers = widget.control.getBool("show_row_numbers", false)!;
    final showCheckboxColumn = widget.control.getBool("show_checkbox_column", false)!;
    final frozenColumnsCount = widget.control.getInt("frozen_columns_count", 0)!;
    final rowHeight = widget.control.getDouble("row_height", 36.0)!;
    final headerRowHeight = widget.control.getDouble("header_row_height", 40.0)!;

    // Build data columns from column defs
    final dataColumns = [
      for (final c in _cols)
        GridColumn(
          columnName: (c as Map)["name"] as String,
          width: _columnWidths[(c as Map)["name"] as String] ?? double.nan,
          label: Container(
            padding: EdgeInsets.symmetric(horizontal: headerPadH, vertical: headerPadV),
            alignment: _alignmentFromString(c["alignment"] as String?),
            child: Text(
              (c["label"] as String?) ?? c["name"] as String,
              style: TextStyle(
                color: headerTextColor,
                fontWeight: headerFontWeight,
                fontSize: headerFontSize,
                fontFamily: fontFamily,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
    ];

    final grid = SfDataGrid(
      source: _source,
      allowEditing: editable,
      allowSorting: allowSorting,
      allowColumnsResizing: allowColumnResize,
      columnResizeMode: ColumnResizeMode.onResize,
      onColumnResizeUpdate: allowColumnResize
          ? (ColumnResizeUpdateDetails details) {
              setState(() {
                _columnWidths[details.column.columnName] = details.width;
              });
              return true;
            }
          : null,
      selectionMode: selectionMode,
      navigationMode: navMode,
      editingGestureType: EditingGestureType.tap,
      columnWidthMode: ColumnWidthMode.lastColumnFill,
      gridLinesVisibility: GridLinesVisibility.both,
      headerGridLinesVisibility: GridLinesVisibility.both,
      showCheckboxColumn: showCheckboxColumn,
      frozenColumnsCount: frozenColumnsCount + (showRowNumbers ? 1 : 0),
      headerRowHeight: headerRowHeight,
      rowHeight: rowHeight,
      columns: [
        if (showRowNumbers) _buildRowNumberColumn(headerBg, headerTextColor, headerFontSize, fontFamily),
        ...dataColumns,
      ],
    );

    final themed = SfDataGridTheme(
      data: SfDataGridThemeData(
        currentCellStyle: DataGridCurrentCellStyle(
          borderColor: currentCellBorderColor,
          borderWidth: currentCellBorderWidth,
        ),
        selectionColor: selectionColor,
        headerColor: headerBg,
        gridLineColor: gridLineColor,
        gridLineStrokeWidth: gridLineWidth,
      ),
      child: grid,
    );

    return ConstrainedControl(control: widget.control, child: themed);
  }

  GridColumn _buildRowNumberColumn(Color headerBgColor, Color headerTextColor, double fontSize, String? fontFamily) {
    return GridColumn(
      columnName: '__row_num__',
      width: 50,
      allowEditing: false,
      allowSorting: false,
      label: Container(
        alignment: Alignment.center,
        color: headerBgColor,
        child: Text('#',
            style: TextStyle(
                color: headerTextColor,
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
                fontFamily: fontFamily)),
      ),
    );
  }

  Alignment _alignmentFromString(String? s) {
    switch (s) {
      case "centerRight":
        return Alignment.centerRight;
      case "center":
        return Alignment.center;
      default:
        return Alignment.centerLeft;
    }
  }
}
