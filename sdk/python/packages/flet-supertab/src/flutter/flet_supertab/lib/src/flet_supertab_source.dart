import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';

typedef CellEditCallback = void Function(
    int rowIndex, String columnName, Object? oldValue, Object? newValue);

class FletDataGridSource extends DataGridSource {
  FletDataGridSource({
    required List<List<Object?>> rows,
    required List<String> columnNames,
    this.onCellEdit,
  }) : _columnNames = columnNames {
    _dataRows = rows;
    _buildDataGridRows();
  }

  final List<String> _columnNames;
  List<List<Object?>> _dataRows = [];
  List<DataGridRow> _rows = [];

  /// Callback when a cell is edited
  final CellEditCallback? onCellEdit;

  /// Holds the new value during editing
  dynamic _newCellValue;

  /// Controller for the TextField editor
  final TextEditingController _editingController = TextEditingController();

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
        final align = cell.columnName == 'id'
            ? Alignment.centerRight
            : Alignment.centerLeft;
        return Container(
          alignment: align,
          padding: const EdgeInsets.all(8),
          child: Text(cell.value?.toString() ?? ''),
        );
      }).toList(),
    );
  }

  @override
  Widget? buildEditWidget(
    DataGridRow dataGridRow,
    RowColumnIndex rowColumnIndex,
    GridColumn column,
    CellSubmit submitCell,
  ) {
    // Get the current cell value
    final displayValue = dataGridRow
            .getCells()
            .firstWhere(
              (cell) => cell.columnName == column.columnName,
              orElse: () => DataGridCell<String>(columnName: '', value: ''),
            )
            .value
            ?.toString() ??
        '';

    _newCellValue = displayValue;
    _editingController.text = displayValue;
    _editingController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: displayValue.length,
    );

    return Container(
      padding: const EdgeInsets.all(8.0),
      alignment: Alignment.centerLeft,
      child: TextField(
        controller: _editingController,
        autofocus: true,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
    // rowColumnIndex.rowIndex is already 0-based for data rows
    final rowIndex = rowColumnIndex.rowIndex;
    final columnName = column.columnName;

    if (rowIndex < 0 || rowIndex >= _dataRows.length) return;

    // Find column index
    final colIndex = _columnNames.indexOf(columnName);
    if (colIndex < 0) return;

    final oldValue = _dataRows[rowIndex][colIndex];
    final newValue = _newCellValue;

    // Only update if value changed
    if (oldValue?.toString() != newValue?.toString()) {
      // Update the underlying data
      _dataRows[rowIndex][colIndex] = newValue;

      // Rebuild the rows
      _buildDataGridRows();
      notifyListeners();

      // Notify callback
      onCellEdit?.call(rowIndex, columnName, oldValue, newValue);
    }
  }
}
