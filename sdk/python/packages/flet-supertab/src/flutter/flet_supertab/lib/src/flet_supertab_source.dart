import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';

typedef CellEditCallback = void Function(
    int rowIndex, String columnName, Object? oldValue, Object? newValue);

typedef PageRequestCallback = void Function(int offset, int limit);
typedef SortRequestCallback = void Function(String columnName, bool ascending);

class FletDataGridSource extends DataGridSource {
  FletDataGridSource({
    required List<List<Object?>> rows,
    List<List<Object?>>? rawRows,
    required List<String> columnNames,
    List<dynamic>? columnDefs,
    this.onCellEdit,
    this.onPageRequest,
    this.onSortRequest,
    DataGridController? gridController,
    this.showRowNumbers = false,
    this.cellTextColor = Colors.transparent,
    this.cellBgColor = Colors.transparent,
    this.alternateRowColor = Colors.transparent,
    this.cellFontSize = 13.0,
    this.fontFamily,
    this.cellPaddingHorizontal = 12.0,
    this.cellPaddingVertical = 4.0,
    this.overrideCells = const {},
    this.cellStyles = const [],
    this.summaryValues = const [],
  })  : _columnNames = columnNames,
        _columnDefs = columnDefs ?? [],
        _rawRows = rawRows ?? [] {
    _gridController = gridController;
    _dataRows = rows;
    _buildColumnTypes();
    _buildDataGridRows();
  }

  final List<String> _columnNames;
  final List<dynamic> _columnDefs;
  List<List<Object?>> _dataRows = [];
  final List<List<Object?>> _rawRows;
  List<DataGridRow> _rows = [];

  /// Per-column type hints: "int", "float", "bool", "str"
  Map<String, String> _columnTypes = {};

  /// Per-column Python format strings (e.g. "${:,.2f}")
  Map<String, String> _columnFormats = {};

  /// Per-column read-only flags
  Set<String> _readOnlyColumns = {};

  /// Whether to prepend a row-number cell to each row
  final bool showRowNumbers;

  /// Styling
  final Color cellTextColor;
  final Color cellBgColor;
  final Color alternateRowColor;
  final double cellFontSize;
  final String? fontFamily;
  final double cellPaddingHorizontal;
  final double cellPaddingVertical;

  /// Set of "rowIndex:columnName" keys identifying cells with overrides
  final Set<String> overrideCells;

  /// Callback when a cell is edited
  final CellEditCallback? onCellEdit;

  /// Callback for page requests (LOD / lazy loading)
  final PageRequestCallback? onPageRequest;

  /// Callback for sort requests — Python-side sort
  final SortRequestCallback? onSortRequest;

  /// Grid controller for programmatic cell navigation (Enter → next row)
  DataGridController? _gridController;

  /// Per-cell styles: cellStyles[rowIndex][colIndex] may be {"bg": "#hex", "fg": "#hex"} or null
  final List<List<Map<String, String>?>> cellStyles;

  /// Python-computed summary values (one per column, in column order)
  final List<String> summaryValues;


  /// Holds the new value during editing
  dynamic _newCellValue;

  /// Controller for the TextField editor
  final TextEditingController _editingController = TextEditingController();

  bool get _hasCellTextColor => cellTextColor != Colors.transparent;
  bool get _hasCellBgColor => cellBgColor != Colors.transparent;
  bool get _hasAlternateRowColor => alternateRowColor != Colors.transparent;

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
    _rows = List.generate(_dataRows.length, (rowIndex) {
      final row = _dataRows[rowIndex];
      final cells = <DataGridCell<Object?>>[];
      if (showRowNumbers) {
        cells.add(DataGridCell<Object?>(
          columnName: '__row_num__',
          value: rowIndex + 1,
        ));
      }
      for (var i = 0; i < _columnNames.length; i++) {
        cells.add(DataGridCell<Object?>(
          columnName: _columnNames[i],
          value: i < row.length ? row[i] : null,
        ));
      }
      return DataGridRow(cells: cells);
    });
  }

  @override
  List<DataGridRow> get rows => _rows;

  @override
  Future<void> performSorting(List<DataGridRow> rows) async {
    // Don't sort locally — fire event to Python for server-side sort.
    // Python computes _sorted_indices and pushes a re-ordered page.
    if (onSortRequest != null && sortedColumns.isNotEmpty) {
      final sc = sortedColumns.first;
      final ascending = sc.sortDirection == DataGridSortDirection.ascending;
      onSortRequest!(sc.name, ascending);
    }
    // Don't call super — prevent Syncfusion from sorting the local rows
  }

  @override
  Future<void> handleLoadMoreRows() async {
    if (onPageRequest != null) {
      onPageRequest!(_dataRows.length, 100);
    }
  }

  @override
  Widget? buildTableSummaryCellWidget(
      GridTableSummaryRow summaryRow,
      GridSummaryColumn? summaryColumn,
      RowColumnIndex rowColumnIndex,
      String summaryValue) {
    if (summaryColumn == null) return null;
    // Find column index by name
    final colIdx = _columnNames.indexOf(summaryColumn.columnName);
    // Account for row-number column offset
    final valueIdx = showRowNumbers ? colIdx : colIdx;
    final text = (valueIdx >= 0 && valueIdx < summaryValues.length)
        ? summaryValues[valueIdx]
        : '';
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: cellPaddingHorizontal, vertical: cellPaddingVertical),
      alignment: Alignment.centerRight,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white24, width: 2)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: cellFontSize,
          fontFamily: fontFamily,
        ),
      ),
    );
  }

  @override
  DataGridRowAdapter buildRow(DataGridRow row) {
    final rowIndex = _rows.indexOf(row);
    final useAltColor = _hasAlternateRowColor && rowIndex.isOdd;
    final cells = row.getCells();

    return DataGridRowAdapter(
      color: useAltColor
          ? alternateRowColor
          : (_hasCellBgColor ? cellBgColor : null),
      cells: List.generate(cells.length, (i) {
        final cell = cells[i];
        // Row-number column: centered, muted style
        if (cell.columnName == '__row_num__') {
          return Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
                horizontal: 4, vertical: cellPaddingVertical),
            child: Text(
              cell.value?.toString() ?? '',
              style: TextStyle(
                fontSize: cellFontSize - 1,
                color: Colors.grey,
                fontFamily: fontFamily,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          );
        }

        // Resolve per-cell style from cellStyles
        // colIndex is the data column index (excluding row-number column)
        final colIndex = showRowNumbers ? i - 1 : i;
        Color? perCellBg;
        Color? perCellFg;
        if (rowIndex >= 0 && rowIndex < cellStyles.length &&
            colIndex >= 0 && colIndex < cellStyles[rowIndex].length) {
          final style = cellStyles[rowIndex][colIndex];
          if (style != null) {
            if (style.containsKey('bg')) {
              perCellBg = _parseHexColor(style['bg']!);
            }
            if (style.containsKey('fg')) {
              perCellFg = _parseHexColor(style['fg']!);
            }
          }
        }

        final isNumeric = _isNumericColumn(cell.columnName);
        final container = Container(
          alignment: isNumeric ? Alignment.centerRight : Alignment.centerLeft,
          padding: EdgeInsets.symmetric(
              horizontal: cellPaddingHorizontal, vertical: cellPaddingVertical),
          color: perCellBg,
          child: Text(
            _formatValue(cell.value, cell.columnName),
            style: TextStyle(
              fontSize: cellFontSize,
              color: perCellFg ?? (_hasCellTextColor ? cellTextColor : null),
              fontFamily: fontFamily,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        );
        // Overlay a small triangle on cells with overrides
        final cellKey = '$rowIndex:${cell.columnName}';
        if (overrideCells.contains(cellKey)) {
          return Stack(
            children: [
              container,
              Positioned(
                top: 0,
                left: 0,
                child: CustomPaint(
                  size: const Size(6, 6),
                  painter: _OverrideTrianglePainter(),
                ),
              ),
            ],
          );
        }
        return container;
      }),
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
    // Block editing on row-number and read-only columns
    if (column.columnName == '__row_num__') return null;
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

    // Use raw (unformatted) value for editing when available
    final rowIndex = rowColumnIndex.rowIndex;
    final colIndex = _columnNames.indexOf(column.columnName);
    String editValue;
    if (colIndex >= 0 && rowIndex >= 0 && rowIndex < _rawRows.length &&
        colIndex < _rawRows[rowIndex].length &&
        _rawRows[rowIndex][colIndex] != null) {
      editValue = _rawRows[rowIndex][colIndex].toString();
    } else {
      editValue = displayValue;
    }

    _newCellValue = editValue;
    _editingController.text = editValue;
    _editingController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: editValue.length,
    );

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: cellPaddingHorizontal / 1.5, vertical: 2),
      alignment: isNumeric ? Alignment.centerRight : Alignment.centerLeft,
      child: TextField(
          controller: _editingController,
          autofocus: true,
          textAlign: isNumeric ? TextAlign.right : TextAlign.left,
          keyboardType: isNumeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          style: TextStyle(
            fontSize: cellFontSize,
            fontFamily: fontFamily,
          ),
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

    // Skip row-number column edits
    if (columnName == '__row_num__') return;

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

    // Enter-to-next-row handled by vendored Syncfusion patch
    // (selection_manager.dart EPYX PATCH at _processKeyDown)
  }
}

Color? _parseHexColor(String hex) {
  hex = hex.replaceAll('#', '');
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  return Color(int.parse(hex, radix: 16));
}

/// Paints a small filled triangle in the top-left corner to indicate an override.
class _OverrideTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.orange;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
