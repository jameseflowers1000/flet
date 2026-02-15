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
    _source = FletDataGridSource(
      rows: _dataRows,
      columnNames: _columnNames,
      columnDefs: _cols,
      onCellEdit: _handleCellEdit,
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

  @override
  Widget build(BuildContext context) {
    final editable = widget.control.getBool("editable", false)!;

    // Read styling properties
    final headerBg =
        _parseColor(widget.control.getString("header_bg_color"), const Color(0xFF2D2D30));
    final headerTextColor =
        _parseColor(widget.control.getString("header_text_color"), Colors.white);
    final gridLineColor =
        _parseColor(widget.control.getString("grid_line_color"), const Color(0xFF3E3E42));

    // Read selection mode
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

    final grid = SfDataGrid(
      source: _source,
      allowEditing: editable,
      selectionMode: selectionMode,
      navigationMode: navMode,
      editingGestureType: EditingGestureType.tap,
      columnWidthMode: ColumnWidthMode.fill,
      gridLinesVisibility: GridLinesVisibility.both,
      headerGridLinesVisibility: GridLinesVisibility.both,
      headerRowHeight: 40,
      rowHeight: 36,
      columns: [
        for (final c in _cols)
          GridColumn(
            columnName: (c as Map)["name"] as String,
            label: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: _alignmentFromString(c["alignment"] as String?),
              child: Text(
                (c["label"] as String?) ?? c["name"] as String,
                style: TextStyle(
                  color: headerTextColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );

    final themed = SfDataGridTheme(
      data: SfDataGridThemeData(
        currentCellStyle: DataGridCurrentCellStyle(
          borderColor: Colors.blue,
          borderWidth: 2,
        ),
        selectionColor: Colors.blue.withValues(alpha: 0.15),
        headerColor: headerBg,
        gridLineColor: gridLineColor,
        gridLineStrokeWidth: 1,
      ),
      child: grid,
    );

    return ConstrainedControl(control: widget.control, child: themed);
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
