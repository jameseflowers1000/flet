import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late DataGridController _gridController;
  List<dynamic> _cols = [];
  List<List<Object?>> _dataRows = [];
  List<List<Object?>> _rawRows = [];
  List<String> _columnNames = [];
  Set<String> _overrideCells = {};
  List<List<Map<String, String>?>> _cellStyles = [];
  List<String> _summaryValues = [];

  /// Tracks user-resized column widths (columnName → width).
  /// Columns not in this map use auto-fill sizing.
  final Map<String, double> _columnWidths = {};

  /// Whether the source needs rebuilding (data changed since last build).
  bool _sourceNeedsRebuild = true;

  /// Vertical scroll controller for tracking visible row position.
  final ScrollController _verticalScroll = ScrollController();

  /// First visible row index (updated on scroll).
  int _firstVisibleRow = 0;

  @override
  void initState() {
    super.initState();
    _gridController = DataGridController();
    _verticalScroll.addListener(_onScroll);
    _parseData();
    // _sourceNeedsRebuild starts true; first build() will create source with context
  }

  void _onScroll() {
    final rh = widget.control.getDouble("row_height", 36.0) ?? 36.0;
    final newFirst = (_verticalScroll.offset / rh).floor();
    if (newFirst != _firstVisibleRow) {
      setState(() { _firstVisibleRow = newFirst; });
    }
  }

  @override
  void dispose() {
    _verticalScroll.removeListener(_onScroll);
    _verticalScroll.dispose();
    _gridController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SuperTabControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseData();
    _sourceNeedsRebuild = true;
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

    final rawRowsJson = widget.control.getString("raw_rows");
    _rawRows = rawRowsJson != null && rawRowsJson.isNotEmpty
        ? (jsonDecode(rawRowsJson) as List)
              .map<List<Object?>>((r) => (r as List).cast<Object?>())
              .toList()
        : [];

    final overrideJson = widget.control.getString("override_cells");
    _overrideCells = overrideJson != null && overrideJson.isNotEmpty
        ? (jsonDecode(overrideJson) as List).cast<String>().toSet()
        : {};

    final cellStylesJson = widget.control.getString("cell_styles");
    if (cellStylesJson != null && cellStylesJson.isNotEmpty) {
      final parsed = jsonDecode(cellStylesJson) as List;
      _cellStyles = parsed.map<List<Map<String, String>?>>((row) {
        return (row as List).map<Map<String, String>?>((cell) {
          if (cell == null) return null;
          return Map<String, String>.from(cell as Map);
        }).toList();
      }).toList();
    } else {
      _cellStyles = [];
    }

    final summaryJson = widget.control.getString("summary_row") ?? "";
    if (summaryJson.isNotEmpty) {
      try {
        _summaryValues = (jsonDecode(summaryJson) as List).cast<String>();
      } catch (_) {
        _summaryValues = [];
      }
    } else {
      _summaryValues = [];
    }
  }

  /// Build the data source. [context] is used for Flet color name resolution;
  /// pass null during initState (before the widget is in the tree).
  void _buildSource(BuildContext? context) {
    final showRowNumbers = widget.control.getBool("show_row_numbers", false)!;
    final cellTextColor = _color("cell_text_color", context, Colors.transparent);
    final cellBgColor = _color("cell_bg_color", context, Colors.transparent);
    final alternateRowColor = _color("alternate_row_color", context, Colors.transparent);
    final cellFontSize = widget.control.getDouble("cell_font_size", 13.0)!;
    final fontFamily = widget.control.getString("font_family");
    final cellPadH = widget.control.getDouble("cell_padding_horizontal", 12.0)!;
    final cellPadV = widget.control.getDouble("cell_padding_vertical", 4.0)!;

    _source = FletDataGridSource(
      rows: _dataRows,
      rawRows: _rawRows,
      columnNames: _columnNames,
      columnDefs: _cols,
      onCellEdit: _handleCellEdit,
      onPageRequest: _handlePageRequest,
      onSortRequest: _handleSortRequest,
      gridController: _gridController,
      showRowNumbers: showRowNumbers,
      cellTextColor: cellTextColor,
      cellBgColor: cellBgColor,
      alternateRowColor: alternateRowColor,
      cellFontSize: cellFontSize,
      fontFamily: fontFamily,
      cellPaddingHorizontal: cellPadH,
      cellPaddingVertical: cellPadV,
      overrideCells: _overrideCells,
      cellStyles: _cellStyles,
      summaryValues: _summaryValues,
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

  void _handlePageRequest(int offset, int limit) {
    final eventData = jsonEncode({
      "offset": offset,
      "limit": limit,
    });
    widget.control.triggerEventWithoutSubscribers("page_request", eventData);
  }

  void _handleSortRequest(String columnName, bool ascending) {
    final eventData = jsonEncode({
      "column": columnName,
      "ascending": ascending,
    });
    widget.control.triggerEventWithoutSubscribers("sort_request", eventData);
  }

  void _handleSelectionChanged(
      List<DataGridRow> addedRows, List<DataGridRow> removedRows) {
    final selectedIndices = <int>[];
    for (var row in _gridController.selectedRows) {
      final idx = _source.rows.indexOf(row);
      if (idx >= 0) selectedIndices.add(idx);
    }
    final eventData = jsonEncode({"selected_rows": selectedIndices});
    widget.control.triggerEventWithoutSubscribers("checkbox_selection", eventData);
  }

  /// Parse a color property using Flet's built-in color resolver.
  /// Handles hex (#FF8C00), Flet names (deeporange, blue, amber700), and
  /// opacity (red,0.5). Falls back to [fallback] on null/empty/parse failure.
  Color _color(String prop, BuildContext? context, Color fallback) {
    return widget.control.getColor(prop, context, fallback) ?? fallback;
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
    // Only rebuild source when data has actually changed (didUpdateWidget),
    // not on every build — recreating the source mid-edit kills _newCellValue.
    if (_sourceNeedsRebuild) {
      _buildSource(context);
      _sourceNeedsRebuild = false;
    }

    final editable = widget.control.getBool("editable", false)!;

    // Colors (using Flet's built-in color parser — supports hex, named, opacity)
    final headerBg = _color("header_bg_color", context, const Color(0xFF2D2D30));
    final headerTextColor = _color("header_text_color", context, Colors.white);
    final gridLineColor = _color("grid_line_color", context, const Color(0xFF3E3E42));
    final selectionColor = _color("selection_color", context, Colors.blue.withValues(alpha: 0.15));
    final currentCellBorderColor = _color("current_cell_border_color", context, Colors.blue);

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

    final allowSorting = widget.control.getBool("allow_sorting", false)!;
    final allowColumnResize = widget.control.getBool("allow_column_resize", false)!;

    // Config properties from ETab
    final showRowNumbers = widget.control.getBool("show_row_numbers", false)!;
    final showCheckboxColumn = widget.control.getBool("show_checkbox_column", false)!;

    // Selection mode
    final selectionModeStr =
        widget.control.getString("selection_mode") ?? "cell";
    SelectionMode selectionMode;
    GridNavigationMode navMode;
    if (showCheckboxColumn) {
      // Checkbox column requires multiple selection mode
      selectionMode = SelectionMode.multiple;
      navMode = GridNavigationMode.row;
    } else {
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
    }
    final frozenColumnsCount = widget.control.getInt("frozen_columns_count", 0)!;
    final frozenRowsCount = widget.control.getInt("frozen_rows_count", 0)!;
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
      controller: _gridController,
      verticalScrollController: _verticalScroll,
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
      onCellSecondaryTap: _handleCellSecondaryTap,
      onSelectionChanged: showCheckboxColumn ? _handleSelectionChanged : null,
      selectionMode: selectionMode,
      navigationMode: navMode,
      editingGestureType: EditingGestureType.tap,
      columnWidthMode: ColumnWidthMode.lastColumnFill,
      gridLinesVisibility: GridLinesVisibility.both,
      headerGridLinesVisibility: GridLinesVisibility.both,
      showCheckboxColumn: showCheckboxColumn,
      frozenColumnsCount: frozenColumnsCount + (showRowNumbers ? 1 : 0),
      frozenRowsCount: frozenRowsCount,
      headerRowHeight: headerRowHeight,
      rowHeight: rowHeight,
      tableSummaryRows: _summaryValues.isNotEmpty && _summaryValues.any((v) => v.isNotEmpty) ? [
        GridTableSummaryRow(
          showSummaryInRow: false,
          position: GridTableSummaryRowPosition.bottom,
          columns: [
            for (final c in _cols)
              GridSummaryColumn(
                name: (c as Map)["name"] as String,
                columnName: c["name"] as String,
                summaryType: GridSummaryType.count, // placeholder — we override rendering
              ),
          ],
        ),
      ] : [],
      loadMoreViewBuilder:
          (BuildContext context, LoadMoreRows loadMoreRows) {
        return FutureBuilder<void>(
          future: loadMoreRows(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Align(
                alignment: Alignment.center,
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              );
            }
            return const SizedBox.shrink();
          },
        );
      },
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

    final errorMessage = widget.control.getString("error_message") ?? "";
    Widget result = errorMessage.isNotEmpty
        ? Column(children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.red.shade900,
              child: Row(children: [
                Icon(Icons.error_outline, color: Colors.red.shade200, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    errorMessage,
                    style: TextStyle(color: Colors.red.shade200, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
            Expanded(child: themed),
          ])
        : themed;

    // Tab header bar: label, ctype badge, status indicators, row count
    final label = widget.control.getString("label") ?? "";
    final ctype = widget.control.getString("ctype") ?? "";
    final sortIndicator = widget.control.getString("sort_indicator") ?? "";
    final filterActive = widget.control.getBool("filter_active", false) ?? false;
    final totalRows = widget.control.getInt("total_rows", 0) ?? 0;
    final rowCount = totalRows > 0 ? totalRows : _dataRows.length;

    if (label.isNotEmpty || ctype.isNotEmpty) {
      result = Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: headerBg,
            child: Row(
              children: [
                if (label.isNotEmpty)
                  Text(label, style: TextStyle(
                    color: headerTextColor, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(width: 8),
                if (ctype.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(ctype, style: TextStyle(
                      color: Colors.blue.shade200, fontSize: 11)),
                  ),
                // Sort/filter status indicators (O1d)
                if (sortIndicator.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.sort, size: 14, color: headerTextColor.withValues(alpha: 0.5)),
                  const SizedBox(width: 2),
                  Text(sortIndicator, style: TextStyle(
                    color: headerTextColor.withValues(alpha: 0.5), fontSize: 10)),
                ],
                if (filterActive) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.filter_alt, size: 14, color: Colors.orange.shade300),
                  const SizedBox(width: 2),
                  Text('filtered', style: TextStyle(
                    color: Colors.orange.shade300, fontSize: 10)),
                ],
                const Spacer(),
                Text(rowCount > 0
                    ? 'row ${_firstVisibleRow + 1} of $rowCount'
                    : '0 rows', style: TextStyle(
                  color: headerTextColor.withValues(alpha: 0.6), fontSize: 11)),
              ],
            ),
          ),
          Expanded(child: result),
        ],
      );
    }

    return LayoutControl(control: widget.control, child: result);
  }

  void _handleCellSecondaryTap(DataGridCellTapDetails details) {
    // Row 0 is header in Syncfusion's RowColumnIndex
    final rowIndex = details.rowColumnIndex.rowIndex - 1;
    final columnName = details.column.columnName;
    if (rowIndex < 0 || columnName == '__row_num__') return;

    // Get the raw cell value for copy
    final colIdx = _columnNames.indexOf(columnName);
    String cellValue = '';
    if (colIdx >= 0 && rowIndex < _rawRows.length && colIdx < _rawRows[rowIndex].length) {
      cellValue = _rawRows[rowIndex][colIdx]?.toString() ?? '';
    } else if (colIdx >= 0 && rowIndex < _dataRows.length && colIdx < _dataRows[rowIndex].length) {
      cellValue = _dataRows[rowIndex][colIdx]?.toString() ?? '';
    }

    final cellKey = '$rowIndex:$columnName';
    final hasOverride = _overrideCells.contains(cellKey);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
        const PopupMenuItem(value: 'paste', child: Text('Paste')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'clear', child: Text('Clear Cell')),
        if (hasOverride) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'remove_override', child: Text('Remove Override')),
        ],
      ],
    ).then((action) {
      if (action == null) return;
      if (action == 'copy') {
        Clipboard.setData(ClipboardData(text: cellValue));
      } else if (action == 'paste') {
        Clipboard.getData(Clipboard.kTextPlain).then((data) {
          if (data?.text != null) {
            final eventData = jsonEncode({
              'action': 'paste',
              'row_index': rowIndex,
              'column_name': columnName,
              'value': data!.text,
            });
            widget.control.triggerEventWithoutSubscribers('context_action', eventData);
          }
        });
      } else {
        // clear or remove_override
        final eventData = jsonEncode({
          'action': action,
          'row_index': rowIndex,
          'column_name': columnName,
        });
        widget.control.triggerEventWithoutSubscribers('context_action', eventData);
      }
    });
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
