import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';

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
    _dataRows =
        (rows as List).map<List<Object?>>((r) => (r as List).cast<Object?>()).toList();
  }

  void _buildSource() {
    _source = FletDataGridSource(
      rows: _dataRows,
      columnNames: _columnNames,
      onCellEdit: _handleCellEdit,
    );
  }

  void _handleCellEdit(
      int rowIndex, String columnName, Object? oldValue, Object? newValue) {
    // Trigger event back to Python with JSON-encoded data
    final eventData = jsonEncode({
      "row_index": rowIndex,
      "column_name": columnName,
      "old_value": oldValue?.toString(),
      "new_value": newValue?.toString(),
    });
    widget.control.triggerEventWithoutSubscribers("cell_edit", eventData);
  }

  @override
  Widget build(BuildContext context) {
    final editable = widget.control.getBool("editable", false)!;

    final grid = SfDataGrid(
      source: _source,
      allowEditing: editable,
      selectionMode: editable ? SelectionMode.single : SelectionMode.none,
      navigationMode:
          editable ? GridNavigationMode.cell : GridNavigationMode.row,
      editingGestureType: EditingGestureType.doubleTap,
      columns: [
        for (final c in _cols)
          GridColumn(
            columnName: (c as Map)["name"] as String,
            label: Container(
              padding: const EdgeInsets.all(16),
              alignment: _alignmentFromString(c["alignment"] as String?),
              child: Text((c["label"] as String?) ?? c["name"] as String),
            ),
          ),
      ],
    );

    return ConstrainedControl(control: widget.control, child: grid);
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
