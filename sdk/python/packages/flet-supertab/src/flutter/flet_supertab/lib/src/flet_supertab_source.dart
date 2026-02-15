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

  /// Per-column Python format strings (e.g. "${:,.2f}")
  Map<String, String> _columnFormats = {};

  /// Per-column read-only flags
  Set<String> _readOnlyColumns = {};

  /// Callback when a cell is edited
  final CellEditCallback? onCellEdit;

  /// Holds the new value during editing
  dynamic _newCellValue;

  /// Controller for the TextField editor
  final TextEditingController _editingController = TextEditingController();

  void _buildColumnTypes() {
    _columnTypes = {};
    _columnFormats = {};
    _readOnlyColumns = {};
    for (var i = 0; i < _columnDefs.length && i < _columnNames.length; i++) {
      final def = _columnDefs[i];
      if (def is Map) {
        final dtype = def["dtype"] as String? ?? "str";
        _columnTypes[_columnNames[i]] = dtype;
        final fmt = def["format"] as String?;
        if (fmt != null && fmt.isNotEmpty) {
          _columnFormats[_columnNames[i]] = fmt;
        }
        if (def["read_only"] == true) {
          _readOnlyColumns.add(_columnNames[i]);
        }
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

    // Check for custom Python format string first
    if (_columnFormats.containsKey(columnName)) {
      final formatted = _applyFormat(value, _columnFormats[columnName]!);
      if (formatted != null) return formatted;
    }

    // Fallback to dtype-based formatting
    final dtype = _columnTypes[columnName] ?? "str";

    if (dtype == "float") {
      final d = value is num
          ? value.toDouble()
          : double.tryParse(value.toString());
      if (d != null) {
        if (d == d.roundToDouble() && d.abs() < 1e15) {
          return d.toInt().toString();
        }
        String s = d.toStringAsFixed(4);
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

  /// Parse and apply a Python format string like "${:,.2f}" or "{:,d}".
  /// Returns null if the format couldn't be applied.
  String? _applyFormat(Object? value, String format) {
    if (value == null) return null;

    // Extract prefix (e.g. "$" from "${:,.2f}")
    String prefix = "";
    String fmt = format;
    if (fmt.startsWith('\$')) {
      prefix = '\$';
      fmt = fmt.substring(1);
    }

    // Match Python format spec: {:,?.?\d*[fd]?}
    final match = RegExp(r'\{:([,]?)\.?(\d*)([fd]?)\}').firstMatch(fmt);
    if (match == null) return null;

    final useCommas = match.group(1) == ",";
    final decStr = match.group(2) ?? "";
    final decimals = decStr.isNotEmpty ? int.parse(decStr) : 0;

    double? numValue =
        value is num ? value.toDouble() : double.tryParse(value.toString());
    if (numValue == null) return null;

    String result;
    if (decimals > 0) {
      result = numValue.toStringAsFixed(decimals);
    } else {
      result = numValue.round().toString();
    }

    if (useCommas) {
      final parts = result.split('.');
      parts[0] = parts[0].replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
      result = parts.join('.');
    }

    return "$prefix$result";
  }

  @override
  Widget? buildEditWidget(
    DataGridRow dataGridRow,
    RowColumnIndex rowColumnIndex,
    GridColumn column,
    CellSubmit submitCell,
  ) {
    // Block editing on read-only columns
    if (_readOnlyColumns.contains(column.columnName)) {
      return null;
    }

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
