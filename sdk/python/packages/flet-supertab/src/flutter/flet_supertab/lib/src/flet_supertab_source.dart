import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';

typedef CellEditCallback = void Function(
    int rowIndex, String columnName, Object? oldValue, Object? newValue);

class FletDataGridSource extends DataGridSource {
  FletDataGridSource({
    required List<List<Object?>> rows,
    required List<String> columnNames,
    List<dynamic>? columnDefs,
    this.onCellEdit,
  })  : _columnNames = columnNames,
        _columnDefs = columnDefs ?? [] {
    _dataRows = rows;
    _buildColumnTypes();
    _buildDataGridRows();
  }

  final List<String> _columnNames;
  final List<dynamic> _columnDefs;
  List<List<Object?>> _dataRows = [];
  List<DataGridRow> _rows = [];

  /// Per-column type hints: "int", "float", "bool", "str"
  Map<String, String> _columnTypes = {};

  /// Callback when a cell is edited
  final CellEditCallback? onCellEdit;

  /// Holds the new value during editing
  dynamic _newCellValue;

  /// Controller for the TextField editor
  final TextEditingController _editingController = TextEditingController();

  void _buildColumnTypes() {
    _columnTypes = {};
    for (var i = 0; i < _columnDefs.length && i < _columnNames.length; i++) {
      final def = _columnDefs[i];
      if (def is Map) {
        final dtype = def["dtype"] as String? ?? "str";
        _columnTypes[_columnNames[i]] = dtype;
      }
    }
  }

  bool _isNumericColumn(String columnName) {
    final dtype = _columnTypes[columnName];
    return dtype == "int" || dtype == "float";
  }

  void _buildDataGridRows() {
    _rows = _dataRows
        .map<DataGridRow>(
          (row) => DataGridRow(
            cells: [
              for (var i = 0; i < _columnNames.length; i++)
                DataGridCell<Object?>(
                  columnName: _columnNames[i],
                  value: i < row.length ? row[i] : null,
                ),
            ],
          ),
        )
        .toList();
  }

  @override
  List<DataGridRow> get rows => _rows;

  @override
  DataGridRowAdapter buildRow(DataGridRow row) {
    return DataGridRowAdapter(
      cells: row.getCells().map<Widget>((cell) {
        final isNumeric = _isNumericColumn(cell.columnName);
        return Container(
          alignment: isNumeric ? Alignment.centerRight : Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            _formatValue(cell.value, cell.columnName),
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
    );
  }

  String _formatValue(Object? value, String columnName) {
    if (value == null) return '';

    final dtype = _columnTypes[columnName] ?? "str";

    if (dtype == "float") {
      // Try to parse as double for formatting
      final d = value is num
          ? value.toDouble()
          : double.tryParse(value.toString());
      if (d != null) {
        // If it's a whole number, show without decimals
        if (d == d.roundToDouble() && d.abs() < 1e15) {
          return d.toInt().toString();
        }
        // Otherwise show up to 4 decimal places, trimming trailing zeros
        String s = d.toStringAsFixed(4);
        // Remove trailing zeros after decimal point
        if (s.contains('.')) {
          s = s.replaceAll(RegExp(r'0+$'), '');
          s = s.replaceAll(RegExp(r'\.$'), '');
        }
        return s;
      }
    }

    if (dtype == "int") {
      final i =
          value is int ? value : int.tryParse(value.toString());
      if (i != null) return i.toString();
    }

    if (dtype == "bool") {
      return value.toString().toLowerCase() == 'true' ? 'Yes' : 'No';
    }

    return value.toString();
  }

  @override
  Widget? buildEditWidget(
    DataGridRow dataGridRow,
    RowColumnIndex rowColumnIndex,
    GridColumn column,
    CellSubmit submitCell,
  ) {
    final displayValue = dataGridRow
            .getCells()
            .firstWhere(
              (cell) => cell.columnName == column.columnName,
              orElse: () => DataGridCell<String>(columnName: '', value: ''),
            )
            .value
            ?.toString() ??
        '';

    final isNumeric = _isNumericColumn(column.columnName);

    _newCellValue = displayValue;
    _editingController.text = displayValue;
    _editingController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: displayValue.length,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      alignment: isNumeric ? Alignment.centerRight : Alignment.centerLeft,
      child: TextField(
        controller: _editingController,
        autofocus: true,
        textAlign: isNumeric ? TextAlign.right : TextAlign.left,
        keyboardType: isNumeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          border: InputBorder.none,
          isDense: true,
        ),
        onChanged: (value) {
          _newCellValue = value;
        },
        onSubmitted: (value) {
          submitCell();
        },
      ),
    );
  }

  @override
  Future<void> onCellSubmit(
    DataGridRow dataGridRow,
    RowColumnIndex rowColumnIndex,
    GridColumn column,
  ) async {
    final rowIndex = rowColumnIndex.rowIndex;
    final columnName = column.columnName;

    if (rowIndex < 0 || rowIndex >= _dataRows.length) return;

    final colIndex = _columnNames.indexOf(columnName);
    if (colIndex < 0) return;

    final oldValue = _dataRows[rowIndex][colIndex];
    final newValue = _newCellValue;

    if (oldValue?.toString() != newValue?.toString()) {
      _dataRows[rowIndex][colIndex] = newValue;
      _buildDataGridRows();
      notifyListeners();
      onCellEdit?.call(rowIndex, columnName, oldValue, newValue);
    }
  }
}
