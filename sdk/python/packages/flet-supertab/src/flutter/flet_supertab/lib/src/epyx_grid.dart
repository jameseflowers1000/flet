// EpyxGrid — Custom grid widget replacing Syncfusion DataGrid.
// Phase 1: Core rendering, scrolling, selection, test bridge.
// Architecture: SliverList + Focus + GestureDetector (from prototype).
//
// References:
//   - SUPERTAB_WIDGET.md §3, §4.6, §4.7, §7 Phase 1
//   - Prototype: ~/Dropbox/current/epyc/exp/spreadsheet_table1/

import 'dart:convert';
import 'dart:math' as math;

import 'package:flet/flet.dart';
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'epyx_grid_source.dart';
import 'epyx_grid_test_api.dart';

/// The main EpyxGrid widget. Reads Flet control properties and renders
/// a virtualized grid using SliverList.
class EpyxGrid extends StatefulWidget {
  final Control control;

  const EpyxGrid({super.key, required this.control});

  @override
  State<EpyxGrid> createState() => _EpyxGridState();
}

class _EpyxGridState extends State<EpyxGrid> {
  // -- Data parsed from control properties --
  late EpyxGridSource _source;
  bool _sourceNeedsRebuild = true;
  bool _sourceInitialized = false;

  // -- Scroll controllers (prototype pattern: bidirectional sync) --
  // keepScrollOffset: false prevents PageStorage from restoring stale
  // scroll positions after widget rebuild, which fights our jumpTo calls.
  final ScrollController _yController = ScrollController(keepScrollOffset: false);
  final ScrollController _xController = ScrollController(keepScrollOffset: false);
  final ScrollController _xHeaderController = ScrollController(keepScrollOffset: false);
  ScrollController? _yRowNumController;
  ScrollController? _yFrozenController;

  // -- Selection state --
  // Anchor: where selection started. End: where it extends to.
  // For single-cell selection, anchor == end.
  int _selectedRow = -1;   // anchor row
  int _selectedCol = -1;   // anchor col
  int _selEndRow = -1;     // selection end row
  int _selEndCol = -1;     // selection end col

  // -- Editing state --
  bool _isEditing = false;
  bool _isCodeMode = false;
  String _editValue = '';
  String _editOriginalValue = '';
  final TextEditingController _editController = TextEditingController();
  final FocusNode _editFocusNode = FocusNode();

  // -- Optimistic edit: show committed value immediately, before Python round-trip --
  // Cleared when Python pushes new data via _onControlChanged.
  final Map<String, String> _pendingEdits = {};

  // -- Scroll tracking for header display --
  int _firstVisibleRow = 0;

  // -- Data version: skip rebuild when data hasn't changed --
  String _lastRowsJson = '';
  String _lastColsJson = '';
  int _lastTotalRows = 0;
  String _lastStylesJson = '';
  String _lastOverridesJson = '';
  String _lastHiddenJson = '';
  String _lastSummaryJson = '';

  // -- Focus node for keyboard handling --
  late FocusNode _focusNode;

  // -- Key for Natural mode auto-scroll (attached to selected row) --
  final GlobalKey _selectedRowKey = GlobalKey();

  // -- Column width overrides from drag resize --
  final Map<int, double> _columnWidthOverrides = {};
  int _resizingCol = -1; // column being resized (-1 = none)

  // -- Checkbox column state --
  final Set<int> _checkedRows = {};

  // -- Validation error cells (red border, auto-clear after 3s) --
  Set<String> _validationErrorCells = {};  // "row:colName" keys

  // -- Hover tracking for render_code --
  int _hoveredRow = -1;
  int _hoveredCol = -1;

  // -- Render code cache: (row,col) → {bg, fg} or null --
  // Invalidated on: scroll (new visible rows), selection change, hover change, data change.
  Map<int, Map<String, String>?> _rowRenderCache = {};
  Map<String, Map<String, String>?> _cellRenderCache = {};
  String _lastRenderCode = '';
  String _lastRowRenderCode = '';
  String _lastRowHeightsJson = '';
  double _lastRowHeight = 36.0;


  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _setupScrollSync();
    _yController.addListener(_onVerticalScroll);
    // Listen for Flet property changes — Control is a ChangeNotifier.
    // When Python pushes new data via _sync_to_control(), the Control
    // notifies listeners. We must rebuild the source to pick up new data.
    widget.control.addListener(_onControlChanged);
  }

  @override
  void dispose() {
    widget.control.removeListener(_onControlChanged);
    _yController.removeListener(_onVerticalScroll);
    _yController.dispose();
    _xController.dispose();
    _xHeaderController.dispose();
    _yRowNumController?.dispose();
    _yFrozenController?.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onControlChanged() {
    if (!mounted) return;

    // Check for validation errors (red border feedback)
    final valErrors = widget.control.getString("validation_errors");
    if (valErrors != null && valErrors.isNotEmpty) {
      try {
        final errors = jsonDecode(valErrors) as List;
        final keys = errors.map<String>((e) => '${e["row"]}:${e["col"]}').toSet();
        setState(() => _validationErrorCells = keys);
        // Auto-clear after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() => _validationErrorCells.clear());
          }
        });
        // Clear the property so it doesn't re-trigger
        widget.control.updateProperties({'validation_errors': null});
      } catch (_) {}
    }

    // Check render script changes FIRST (before data version early-return).
    // render_code can change independently of data.
    final newRenderCode = widget.control.getString("render_code") ?? '';
    final newRowRenderCode = widget.control.getString("row_render_code") ?? '';
    if (newRenderCode != _lastRenderCode || newRowRenderCode != _lastRowRenderCode) {
      _lastRenderCode = newRenderCode;
      _lastRowRenderCode = newRowRenderCode;
      _invalidateRenderCaches();
      setState(() {}); // force rebuild with new scripts
    }

    // Skip full rebuild if data hasn't changed.
    final newRows = widget.control.getString("rows") ?? '';
    final newCols = widget.control.getString("columns") ?? '';
    final newTotalRows = widget.control.getInt("total_rows", 0) ?? 0;
    final newStyles = widget.control.getString("cell_styles") ?? '';
    final newOverrides = widget.control.getString("override_cells") ?? '';
    final newHidden = widget.control.getString("hidden_columns") ?? '';
    final newSummary = widget.control.getString("summary_row") ?? '';
    final newRowHeights = widget.control.getString("row_heights") ?? '';
    final newRowHeight = widget.control.getDouble("row_height", 36.0) ?? 36.0;
    final dataKey = '$newRows|$newCols|$newTotalRows|$newStyles|$newOverrides|$newHidden|$newSummary|$newRowHeights|$newRowHeight';
    final oldKey = '$_lastRowsJson|$_lastColsJson|$_lastTotalRows|$_lastStylesJson|$_lastOverridesJson|$_lastHiddenJson|$_lastSummaryJson|$_lastRowHeightsJson|$_lastRowHeight';
    if (dataKey == oldKey) {
      if (_pendingEdits.isNotEmpty) {
        setState(() => _pendingEdits.clear());
      }
      return;
    }
    _lastRowsJson = newRows;
    _lastColsJson = newCols;
    _lastTotalRows = newTotalRows;
    _lastStylesJson = newStyles;
    _lastOverridesJson = newOverrides;
    _lastHiddenJson = newHidden;
    _lastSummaryJson = newSummary;
    _lastRowHeightsJson = newRowHeights;
    _lastRowHeight = newRowHeight;

    setState(() {
      _sourceNeedsRebuild = true;
      _lastRequestedOffset = -1; // reset LOD dedup — data changed
      _pendingEdits.clear(); // Python has authoritative data now
      _invalidateRenderCaches(); // data changed → re-evaluate styles
    });
  }

  @override
  void didUpdateWidget(covariant EpyxGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.control != widget.control) {
      oldWidget.control.removeListener(_onControlChanged);
      widget.control.addListener(_onControlChanged);
    }
    _sourceNeedsRebuild = true;

    // Handle test commands if test mode is active
    if (EpyxGridTestApi.isTestMode) {
      final testCmd = widget.control.getString("test_command");
      if (testCmd != null && testCmd.isNotEmpty) {
        _handleTestCommand(testCmd);
      }
    }
  }

  void _handleTestCommand(String commandJson) {
    final api = EpyxGridTestApi(
      control: widget.control,
      getCellText: (row, col) => _source.cellText(row, col),
      getSelection: () => {'row': _selectedRow, 'col': _selectedCol},
      getSelectionRange: () => {
        'row': _selectedRow, 'col': _selectedCol,
        'end_row': _selEndRow, 'end_col': _selEndCol,
      },
      getColumnWidth: (col) => _getColumnWidth(col),
      getIsEditing: () => _isEditing,
      getVisibleRowCount: () {
        if (!_yController.hasClients) return 0;
        return (_yController.position.viewportDimension / _source.rowHeight)
            .floor();
      },
      getFirstVisibleRow: () => _firstVisibleRow,
      simulateTap: (row, col) {
        _moveTo(row, col);
      },
      simulateRightClick: (row, col) {
        _moveTo(row, col);
        final renderBox = context.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          final pos = renderBox.localToGlobal(Offset.zero);
          double colX = 0;
          for (int i = 0; i < col; i++) colX += _getColumnWidth(i);
          final x = pos.dx + colX + _getColumnWidth(col) / 2;
          final y = pos.dy + 26.0 + _source.headerRowHeight +
                    (row - _firstVisibleRow) * _source.rowHeight +
                    _source.rowHeight / 2;
          _showContextMenu(Offset(x, y), row, col);
        }
      },
      simulateTypeText: (text) {
        if (_isEditing) {
          _editController.text = text;
        } else {
          // Start editing and set text
          setState(() {
            _isEditing = true;
            _editOriginalValue = _source.cellText(_selectedRow, _selectedCol);
            _editController.text = text;
          });
        }
      },
      scrollToRow: (row) {
        if (_yController.hasClients) {
          final offset = row * _source.rowHeight;
          _yController.jumpTo(offset.clamp(
              0.0, _yController.position.maxScrollExtent));
        }
      },
      resizeColumn: (col, delta) {
        final currentWidth = _getColumnWidth(col);
        final newWidth = (currentWidth + delta).clamp(30.0, 1000.0);
        _columnWidthOverrides[col] = newWidth;
        // Fire column resize event to Python
        final colName = _source.columnName(col);
        widget.control.triggerEventWithoutSubscribers(
            'column_resize', jsonEncode({
              'column': colName, 'width': newWidth,
            }));
        setState(() {});
      },
      getGridGeometry: () {
        final colWidths = <double>[];
        for (int i = 0; i < _source.columnCount; i++) {
          colWidths.add(_getColumnWidth(i));
        }
        // Absolute screen position of this widget
        double screenX = 0, screenY = 0;
        try {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox != null) {
            final pos = renderBox.localToGlobal(Offset.zero);
            screenX = pos.dx;
            screenY = pos.dy;
          }
        } catch (_) {}
        return {
          'col_widths': colWidths,
          'row_height': _source.rowHeight,
          'header_height': _source.headerRowHeight,
          'chrome_height': 26.0,
          'row_count': _source.rowCount,
          'col_count': _source.columnCount,
          'col_names': List.generate(
              _source.columnCount, (i) => _source.columnName(i)),
          'total_columns_width': _totalColumnsWidth,
          'screen_x': screenX,
          'screen_y': screenY,
          'scroll_x': _xController.hasClients ? _xController.offset : 0.0,
          'scroll_y': _yController.hasClients ? _yController.offset : 0.0,
          'cell_padding_h': _source.cellPaddingH,
          'cell_padding_v': _source.cellPaddingV,
          'has_override': List.generate(
              _source.rowCount,
              (r) => List.generate(
                  _source.columnCount,
                  (c) => _source.hasOverride(r, c))),
        };
      },
      simulateKey: (key, modifiers) {
        // Simulate key press through the same handler
        // This is a simplified version — full key simulation would
        // create and dispatch actual KeyEvent objects
        if (key == 'Arrow_Down' && _selectedRow < _source.rowCount - 1) {
          setState(() => _selectedRow++);
        } else if (key == 'Arrow_Up' && _selectedRow > 0) {
          setState(() => _selectedRow--);
        } else if (key == 'Arrow_Right' &&
            _selectedCol < _source.columnCount - 1) {
          setState(() => _selectedCol++);
        } else if (key == 'Arrow_Left' && _selectedCol > 0) {
          setState(() => _selectedCol--);
        }
      },
    );

    final result = api.handleCommand(commandJson);
    // Send result back to Python via control property
    widget.control.triggerEventWithoutSubscribers("test_result", result);
  }

  /// Set up bidirectional scroll sync between body and header (prototype pattern).
  void _setupScrollSync() {
    _xController.addListener(() {
      if (_xHeaderController.hasClients &&
          _xHeaderController.offset != _xController.offset) {
        _xHeaderController.jumpTo(_xController.offset);
      }
    });
    _xHeaderController.addListener(() {
      if (_xController.hasClients &&
          _xController.offset != _xHeaderController.offset) {
        _xController.jumpTo(_xHeaderController.offset);
      }
    });
  }

  /// Track first visible row for header display + LOD page requests.
  void _onVerticalScroll() {
    if (!_sourceInitialized) return;
    final rh = _source.rowHeight;
    final newFirst = (_yController.offset / rh).floor();
    if (newFirst != _firstVisibleRow) {
      setState(() {
        _firstVisibleRow = newFirst;
      });
    }

    // LOD: fire page_request at 70% of loaded data
    final totalRows = widget.control.getInt("total_rows", 0) ?? 0;
    if (totalRows > _source.rowCount && _yController.hasClients) {
      final maxScroll = _yController.position.maxScrollExtent;
      if (maxScroll > 0 &&
          _yController.offset / maxScroll > 0.7) {
        final eventData = jsonEncode({
          "offset": _source.rowCount,
          "limit": 100,
        });
        widget.control
            .triggerEventWithoutSubscribers("page_request", eventData);
      }
    }
  }

  // -- Property reading helpers (same pattern as current SuperTabControl) --

  Color _color(String prop, BuildContext? ctx, Color fallback) {
    return widget.control.getColor(prop, ctx, fallback) ?? fallback;
  }

  // ────────────────────────────────────────────────────────────────
  // Build
  // ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_sourceNeedsRebuild || !_sourceInitialized) {
      _source = EpyxGridSource.fromControl(widget.control, context);
      _sourceNeedsRebuild = false;
      // Cache data version for change detection
      _lastRowsJson = widget.control.getString("rows") ?? '';
      _lastColsJson = widget.control.getString("columns") ?? '';
      _lastTotalRows = widget.control.getInt("total_rows", 0) ?? 0;
      _lastStylesJson = widget.control.getString("cell_styles") ?? '';
      _lastOverridesJson = widget.control.getString("override_cells") ?? '';
      _lastHiddenJson = widget.control.getString("hidden_columns") ?? '';
      _lastSummaryJson = widget.control.getString("summary_row") ?? '';
      _sourceInitialized = true;
    }
    final totalRows = widget.control.getInt("total_rows", 0) ?? 0;
    final label = widget.control.getString("label") ?? "";
    final ctype = widget.control.getString("ctype") ?? "";
    final sortIndicator = widget.control.getString("sort_indicator") ?? "";
    final filterActive = widget.control.getBool("filter_active", false) ?? false;

    // Row count for display
    final visibleEnd = math.min(
        _firstVisibleRow + _source.visibleRowEstimate, _source.rowCount);
    final rowPositionText = _source.rowCount > 0
        ? "rows ${_firstVisibleRow + 1}-$visibleEnd of "
            "${totalRows > 0 ? totalRows : _source.rowCount}"
        : "0 rows";

    // -- Error message --
    final errorMessage = widget.control.getString("error_message") ?? "";

    // -- Header bar --
    final headerBar = _buildHeaderBar(
        label, ctype, sortIndicator, filterActive, rowPositionText, context);

    // -- Summary row data --
    final summaryJson = widget.control.getString("summary_row") ?? "";
    List<String> summaryValues = [];
    if (summaryJson.isNotEmpty) {
      try {
        summaryValues = (jsonDecode(summaryJson) as List)
            .map<String>((e) => e?.toString() ?? '')
            .toList();
      } catch (_) {}
    }

    // -- Grid body --
    final gridBody = _source.rowCount == 0
        ? const Center(
            child: Text("No data",
                style: TextStyle(color: Colors.grey, fontSize: 14)))
        : _buildGridBody(context, summaryValues: summaryValues);

    final errorBanner = errorMessage.isNotEmpty
        ? Container(
            color: Colors.red.shade900,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.white, size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(errorMessage,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          )
        : null;

    // Use LayoutBuilder to handle bounded vs unbounded height.
    // Bounded (Gallery/Fit): Expanded fills available space.
    // Unbounded (Natural mode): grid body determines own height (no Expanded).
    return LayoutControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final unbounded = constraints.maxHeight == double.infinity;

          if (unbounded) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                headerBar,
                if (errorBanner != null) errorBanner,
                gridBody,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              headerBar,
              if (errorBanner != null) errorBanner,
              Expanded(child: gridBody),
            ],
          );
        },
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Header bar (H1-H5)
  // ────────────────────────────────────────────────────────────────

  Widget _buildHeaderBar(String label, String ctype, String sortIndicator,
      bool filterActive, String rowPositionText, BuildContext context) {
    final headerBg =
        _color("header_bg_color", context, const Color(0xFF2D2D30));

    // CustomPaint paints background only to _totalColumnsWidth so the
    // chrome bar colour stops at the last column boundary.
    return GestureDetector(
      onSecondaryTapDown: (d) => _showChromeContextMenu(d.globalPosition),
      child: CustomPaint(
      painter: _BarBgPainter(headerBg, _totalColumnsWidth, rowPositionText),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            // H1: Table label
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
              ),
            // H2: Ctype badge
            if (ctype.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade700,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(ctype,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            // H4: Sort indicator
            if (sortIndicator.isNotEmpty) ...[
              const SizedBox(width: 8),
              Icon(Icons.sort, size: 14, color: Colors.grey.shade400),
              const SizedBox(width: 2),
              Text(sortIndicator,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 10)),
            ],
            // H5: Filter indicator
            if (filterActive) ...[
              const SizedBox(width: 8),
              Icon(Icons.filter_alt, size: 14, color: Colors.orange.shade400),
              const SizedBox(width: 2),
              Text("filtered",
                  style: TextStyle(color: Colors.orange.shade400, fontSize: 10)),
            ],
          ],
        ),
      ),
      ),
    );
  }

  /// Chrome bar right-click context menu — table-level actions.
  void _showChromeContextMenu(Offset globalPosition) {
    final allowAddRow =
        widget.control.getBool("allow_add_row", true) ?? true;
    if (!allowAddRow) return;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx, globalPosition.dy,
        globalPosition.dx, globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(value: 'add_1',
            child: Text('Add Row')),
        const PopupMenuItem(value: 'add_n',
            child: Text('Add Rows…')),
      ],
    ).then((action) {
      if (action == null) return;
      if (action == 'add_1') {
        widget.control.triggerEventWithoutSubscribers(
            'context_action', jsonEncode({
              'action': 'add_rows', 'count': 1,
            }));
      } else if (action == 'add_n') {
        _showAddRowsDialog();
      }
    });
  }

  void _showAddRowsDialog() {
    final controller = TextEditingController(text: '5');
    showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Rows'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Number of rows'),
          onSubmitted: (_) {
            final n = int.tryParse(controller.text) ?? 0;
            Navigator.of(ctx).pop(n);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () {
                final n = int.tryParse(controller.text) ?? 0;
                Navigator.of(ctx).pop(n);
              },
              child: const Text('Add')),
        ],
      ),
    ).then((count) {
      if (count != null && count > 0) {
        widget.control.triggerEventWithoutSubscribers(
            'context_action', jsonEncode({
              'action': 'add_rows', 'count': count,
            }));
      }
    });
  }

  // ────────────────────────────────────────────────────────────────
  // Grid body: column headers + SliverList rows
  // ────────────────────────────────────────────────────────────────

  Widget _buildGridBody(BuildContext context,
      {List<String> summaryValues = const []}) {
    final showRowNumbers =
        widget.control.getBool("show_row_numbers", false) ?? false;
    final rowNumWidth = showRowNumbers ? _rowNumberWidth() : 0.0;
    final frozenCount = widget.control.getInt("frozen_columns_count", 0) ?? 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Set available width for last-column-fill calculation
        final dataWidth = constraints.maxWidth - rowNumWidth;
        _source.setAvailableWidth(dataWidth);

        final unbounded = constraints.maxHeight == double.infinity;
        final totalRows = widget.control.getInt("total_rows", 0) ?? 0;
        final hasMore = totalRows > _source.rowCount;
        final itemCount = _source.rowCount + (hasMore ? 1 : 0);

        Widget lodSpinner() => const Center(
              child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            );

        // When frozen columns are active, split into frozen + scrollable panels
        if (frozenCount > 0 && frozenCount < _source.columnCount) {
          final frozenWidth = _frozenColumnsWidth(frozenCount);
          final scrollableWidth = _scrollableColumnsWidth(frozenCount);

          return Focus(
            focusNode: _focusNode,
            onKeyEvent: _onKeyEvent,
            child: GestureDetector(
              onTapDown: (details) => _onTapDown(details),
              onSecondaryTapDown: (details) => _onSecondaryTapDown(details),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Frozen panel (no horizontal scroll)
                  SizedBox(
                    width: frozenWidth,
                    child: Column(
                      mainAxisSize: unbounded ? MainAxisSize.min : MainAxisSize.max,
                      children: [
                        _buildColumnHeaderRow(context, showRowNumbers, rowNumWidth,
                            colStart: 0, colEnd: frozenCount),
                        if (unbounded)
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: itemCount,
                            itemExtent: _source.hasVariableRowHeights ? null : _source.rowHeight,
                            itemBuilder: (context, index) {
                              if (index >= _source.rowCount) {
                                _requestNextPage();
                                return lodSpinner();
                              }
                              return _buildRow(index, colEnd: frozenCount);
                            },
                          )
                        else
                          Expanded(
                            child: ListView.builder(
                              controller: _getFrozenController(),
                              itemCount: itemCount,
                              itemExtent: _source.hasVariableRowHeights ? null : _source.rowHeight,
                              itemBuilder: (context, index) {
                                if (index >= _source.rowCount) {
                                  _requestNextPage();
                                  return lodSpinner();
                                }
                                return _buildRow(index, colEnd: frozenCount);
                              },
                            ),
                          ),
                        if (summaryValues.isNotEmpty)
                          _buildSummaryRow(summaryValues, colEnd: frozenCount),
                      ],
                    ),
                  ),
                  // Divider line between frozen and scrollable
                  Container(width: 2, color: _source.gridLineColor),
                  // Scrollable panel
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _xController,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: scrollableWidth,
                        child: Column(
                          mainAxisSize: unbounded ? MainAxisSize.min : MainAxisSize.max,
                          children: [
                            _buildColumnHeaderRow(context, showRowNumbers, 0,
                                colStart: frozenCount),
                            if (unbounded)
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: itemCount,
                                itemExtent: _source.hasVariableRowHeights ? null : _source.rowHeight,
                                itemBuilder: (context, index) {
                                  if (index >= _source.rowCount) return lodSpinner();
                                  return _buildRow(index, colStart: frozenCount);
                                },
                              )
                            else
                              Expanded(
                                child: ListView.builder(
                                  controller: _yController,
                                  itemCount: itemCount,
                                  itemExtent: _source.hasVariableRowHeights ? null : _source.rowHeight,
                                  itemBuilder: (context, index) {
                                    if (index >= _source.rowCount) return lodSpinner();
                                    return _buildRow(index, colStart: frozenCount);
                                  },
                                ),
                              ),
                            if (summaryValues.isNotEmpty)
                              _buildSummaryRow(summaryValues, colStart: frozenCount),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // No frozen columns: single horizontal scroll wraps everything
        final frozenRows = widget.control.getInt("frozen_rows_count", 0) ?? 0;
        final scrollableRowCount = itemCount - frozenRows;

        return MouseRegion(
          onHover: (event) => _onHover(event.localPosition),
          onExit: (_) => _onHoverExit(),
          child: Focus(
            focusNode: _focusNode,
            onKeyEvent: _onKeyEvent,
            child: GestureDetector(
              onTapDown: (details) => _onTapDown(details),
              onSecondaryTapDown: (details) => _onSecondaryTapDown(details),
              child: SingleChildScrollView(
              controller: _xController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: SizedBox(
                width: _totalColumnsWidth,
                child: Column(
                  mainAxisSize: unbounded ? MainAxisSize.min : MainAxisSize.max,
                  children: [
                    _buildColumnHeaderRow(context, showRowNumbers, rowNumWidth),
                    // Frozen rows: pinned above scrollable body
                    if (frozenRows > 0)
                      for (int i = 0; i < frozenRows && i < _source.rowCount; i++)
                        _buildRow(i),
                    if (unbounded)
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: scrollableRowCount.clamp(0, itemCount),
                        // itemExtent only when uniform — variable heights
                        // need the builder to size each row independently
                        itemExtent: _source.hasVariableRowHeights
                            ? null : _source.rowHeight,
                        itemBuilder: (context, index) {
                          final actualRow = index + frozenRows;
                          if (actualRow >= _source.rowCount) {
                            _requestNextPage();
                            return lodSpinner();
                          }
                          return _buildRow(actualRow);
                        },
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          controller: _yController,
                          itemCount: scrollableRowCount.clamp(0, itemCount),
                          itemExtent: _source.hasVariableRowHeights
                              ? null : _source.rowHeight,
                          itemBuilder: (context, index) {
                            final actualRow = index + frozenRows;
                            if (actualRow >= _source.rowCount) {
                              _requestNextPage();
                              return lodSpinner();
                            }
                            return _buildRow(actualRow);
                          },
                        ),
                      ),
                    if (summaryValues.isNotEmpty)
                      _buildSummaryRow(summaryValues),
                  ],
                ),
              ),
            ),
          ),
        ),
        );
      },
    );
  }

  /// Summary row — fixed footer with aggregated values.
  Widget _buildSummaryRow(List<String> values,
      {int colStart = 0, int? colEnd}) {
    final endCol = colEnd ?? _source.columnCount;
    final headerBg =
        _color("header_bg_color", context, const Color(0xFF2D2D30));

    return Container(
      height: _source.rowHeight,
      decoration: BoxDecoration(
        color: headerBg,
        border: Border(
          top: BorderSide(
              color: _source.gridLineColor, width: _source.gridLineWidth * 2),
        ),
      ),
      child: Row(
        children: [
          for (int i = colStart; i < endCol; i++)
            if (!_source.isColumnHidden(i))
              Container(
                width: _getColumnWidth(i),
                height: _source.rowHeight,
                padding: EdgeInsets.symmetric(
                  horizontal: _source.cellPaddingH,
                  vertical: _source.cellPaddingV,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                        color: _source.gridLineColor,
                        width: _source.gridLineWidth),
                  ),
                ),
                alignment: _source.isNumericColumn(i)
                    ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Text(
                i < values.length ? values[i] : '',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: _source.cellFontSize,
                  fontFamily: _source.fontFamily,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  /// Column header row — inside the shared horizontal SingleChildScrollView.
  Widget _buildColumnHeaderRow(
      BuildContext context, bool showRowNumbers, double rowNumWidth,
      {int colStart = 0, int? colEnd}) {
    final headerBg =
        _color("header_bg_color", context, const Color(0xFF2D2D30));
    final headerTextColor =
        _color("header_text_color", context, Colors.white);
    final headerFontSize =
        widget.control.getDouble("header_font_size", 13.0) ?? 13.0;
    final headerRowHeight =
        widget.control.getDouble("header_row_height", 40.0) ?? 40.0;
    final headerPadH =
        widget.control.getDouble("header_padding_horizontal", 12.0) ?? 12.0;

    final endCol = colEnd ?? _source.columnCount;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;

    return Container(
      height: headerRowHeight,
      color: headerBg,
      child: Row(
        children: [
          // Select-all checkbox in header (only in leftmost panel)
          if (showCheckbox && colStart == 0)
            SizedBox(
              width: _checkboxColWidth,
              height: headerRowHeight,
              child: Center(
                child: SizedBox(
                  width: 18, height: 18,
                  child: Checkbox(
                    value: _checkedRows.length == _source.rowCount &&
                        _source.rowCount > 0,
                    tristate: true,
                    onChanged: (v) => _toggleAllCheckboxes(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          for (int i = colStart; i < endCol; i++)
            if (!_source.isColumnHidden(i))
              GestureDetector(
                onTap: () => _onHeaderTap(i),
                onSecondaryTapDown: (d) =>
                    _showHeaderContextMenu(d.globalPosition, i),
                child: SizedBox(
                  width: _getColumnWidth(i),
                  height: headerRowHeight,
                  child: Stack(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: headerPadH),
                      alignment: _source.isNumericColumn(i)
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                              color: _source.gridLineColor,
                              width: _source.gridLineWidth),
                          bottom: BorderSide(
                              color: _source.gridLineColor,
                              width: _source.gridLineWidth),
                        ),
                      ),
                      child: Text(
                        _source.columnLabel(i),
                        style: TextStyle(
                          color: headerTextColor,
                          fontSize: headerFontSize,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Resize handle
                    Positioned(
                      right: 0, top: 0, bottom: 0,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          onHorizontalDragStart: (_) {
                            setState(() => _resizingCol = i);
                          },
                          onHorizontalDragUpdate: (d) {
                            setState(() {
                              final current = _getColumnWidth(i);
                              _columnWidthOverrides[i] =
                                  (current + d.delta.dx).clamp(40.0, 4000.0);
                            });
                          },
                          onHorizontalDragEnd: (_) {
                            setState(() => _resizingCol = -1);
                            _fireColumnResize(i);
                          },
                          onDoubleTap: () => _autoSizeColumn(i),
                          behavior: HitTestBehavior.opaque,
                          child: const SizedBox(width: 12),
                        ),
                      ),
                    ),
                    if (_resizingCol == i)
                      Positioned(
                        right: 8, top: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('${_getColumnWidth(i).round()}px',
                              style: const TextStyle(color: Colors.white, fontSize: 10)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Old _buildColumnHeaders, _buildDataArea, _buildRowNumberColumn,
  // _buildScrollableGrid removed — replaced by unified scroll in _buildGridBody.

  // ────────────────────────────────────────────────────────────────
  // LOD page request
  // ────────────────────────────────────────────────────────────────

  int _lastRequestedOffset = -1;

  /// Request next page of data from Python. Debounced by offset to avoid
  /// duplicate requests for the same page.
  void _requestNextPage() {
    final offset = _source.rowCount;
    if (offset == _lastRequestedOffset) return; // already requested
    _lastRequestedOffset = offset;

    final eventData = jsonEncode({
      "offset": offset,
      "limit": 100,
    });
    widget.control.triggerEventWithoutSubscribers("page_request", eventData);
  }

  // ────────────────────────────────────────────────────────────────
  // Row rendering
  // ────────────────────────────────────────────────────────────────

  static const double _checkboxColWidth = 40.0;

  Widget _buildRow(int rowIndex, {int colStart = 0, int? colEnd}) {
    final isSelected = rowIndex == _selectedRow;
    final endCol = colEnd ?? _source.columnCount;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;

    // Apply row_render_code (§6A Layer 5)
    Color? rowBg = _source.rowBackground(rowIndex, isSelected);
    final rowRender = _evalRowRender(rowIndex);
    if (rowRender != null && rowRender['bg'] != null) {
      rowBg = _parseHexColor(rowRender['bg']!) ?? rowBg;
    }

    return Container(
      key: (isSelected && colStart == 0) ? _selectedRowKey : null,
      height: _source.getRowHeight(rowIndex),
      decoration: BoxDecoration(
        color: rowBg,
        border: Border(
          bottom: BorderSide(
              color: _source.gridLineColor, width: _source.gridLineWidth),
        ),
      ),
      child: Row(
        children: [
          // Checkbox column (only in leftmost panel)
          if (showCheckbox && colStart == 0)
            SizedBox(
              width: _checkboxColWidth,
              height: _source.getRowHeight(rowIndex),
              child: Center(
                child: SizedBox(
                  width: 18, height: 18,
                  child: Checkbox(
                    value: _checkedRows.contains(rowIndex),
                    onChanged: (v) => _toggleCheckbox(rowIndex, v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          for (int colIndex = colStart; colIndex < endCol; colIndex++)
            if (!_source.isColumnHidden(colIndex))
              _buildCell(rowIndex, colIndex),
        ],
      ),
    );
  }

  Widget _buildCell(int rowIndex, int colIndex) {
    final isAnchor = _isAnchor(rowIndex, colIndex);
    final inRange = _isInSelection(rowIndex, colIndex);
    // Show optimistic edit value if pending, otherwise source value
    final pendingKey = '$rowIndex:$colIndex';
    final cellText = _pendingEdits[pendingKey] ??
        _source.cellText(rowIndex, colIndex);
    final cellStyle = _source.cellStyle(rowIndex, colIndex);

    Color? fg = cellStyle?['fg'] != null
        ? _parseHexColor(cellStyle!['fg']!)
        : null;
    Color? bg = cellStyle?['bg'] != null
        ? _parseHexColor(cellStyle!['bg']!)
        : null;

    // Apply render_code (§6A Layer 5 — overrides Python Layers 1-4)
    final cellRender = _evalCellRender(rowIndex, colIndex);
    if (cellRender != null) {
      if (cellRender['bg'] != null) bg = _parseHexColor(cellRender['bg']!) ?? bg;
      if (cellRender['fg'] != null) fg = _parseHexColor(cellRender['fg']!) ?? fg;
    }

    final textColor = fg ?? _source.cellTextColor;
    // Range highlight: light blue tint for non-anchor cells in selection
    final bgColor = isAnchor
        ? bg
        : inRange
            ? (bg ?? const Color(0xFF1E1E1E)).withValues(alpha: 0.8)
            : bg;

    final isEditingThis = _isEditing && isAnchor;

    // Validation error: red border overrides all other borders
    final colName = colIndex < _source.columnCount
        ? _source.columnName(colIndex) : '';
    final hasValidationError =
        _validationErrorCells.contains('$rowIndex:$colName');

    // Selection border: anchor gets solid border, range gets thin highlight
    BoxBorder cellBorder;
    if (hasValidationError) {
      cellBorder = Border.all(color: Colors.red, width: 2.0);
    } else if (isAnchor) {
      cellBorder = Border.all(
        color: _source.currentCellBorderColor,
        width: _source.currentCellBorderWidth,
      );
    } else if (inRange) {
      cellBorder = Border.all(
        color: _source.currentCellBorderColor.withValues(alpha: 0.4),
        width: 1.0,
      );
    } else {
      cellBorder = Border(
        right: BorderSide(
            color: _source.gridLineColor,
            width: _source.gridLineWidth),
      );
    }

    final hasOverride = _source.hasOverride(rowIndex, colIndex);
    return Semantics(
      label: 'cell_${rowIndex}_${colIndex}_$cellText',
      child: CustomPaint(
        // Override triangle: foregroundPainter draws ON TOP of the Container
        // at the cell's (0,0) — the outer border corner.  This avoids the
        // negative-offset Positioned that gets clipped by RepaintBoundary.
        foregroundPainter: hasOverride ? _OverrideTrianglePainter() : null,
        child: Container(
          width: _getColumnWidth(colIndex),
          height: _source.getRowHeight(rowIndex),
          padding: EdgeInsets.symmetric(
            horizontal: _source.cellPaddingH,
            vertical: _source.cellPaddingV,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            border: cellBorder,
          ),
          child: Align(
            alignment: _source.isNumericColumn(colIndex)
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: isEditingThis
                ? TextField(
                    controller: _editController,
                    focusNode: _editFocusNode,
                    autofocus: true,
                    style: TextStyle(
                      fontSize: _source.cellFontSize,
                      fontFamily: _source.fontFamily,
                    ),
                    maxLines: _isCodeMode ? null : 1,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _commitEdit(moveDown: true),
                  )
                : Text(
                    cellText,
                    style: TextStyle(
                      color: textColor == Colors.transparent ? null : textColor,
                      fontSize: _source.cellFontSize,
                      fontFamily: _source.fontFamily,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Selection range helpers
  // ────────────────────────────────────────────────────────────────

  /// Selection bounds (top-left to bottom-right).
  int get _selMinRow => math.min(_selectedRow, _selEndRow);
  int get _selMaxRow => math.max(_selectedRow, _selEndRow);
  int get _selMinCol => math.min(_selectedCol, _selEndCol);
  int get _selMaxCol => math.max(_selectedCol, _selEndCol);

  /// Is this cell within the current selection range?
  bool _isInSelection(int row, int col) {
    if (_selectedRow < 0) return false;
    return row >= _selMinRow && row <= _selMaxRow &&
           col >= _selMinCol && col <= _selMaxCol;
  }

  /// Is this the anchor cell (current/active cell)?
  bool _isAnchor(int row, int col) {
    return row == _selectedRow && col == _selectedCol;
  }

  /// Is the selection a multi-cell range?
  bool get _hasRange =>
      _selectedRow >= 0 && (_selectedRow != _selEndRow || _selectedCol != _selEndCol);

  /// Move anchor (and collapse range unless extending).
  /// Set scroll=false for tap events (cell already visible).
  void _moveTo(int row, int col, {bool extend = false, bool scroll = true}) {
    final prevRow = _selectedRow;
    final prevCol = _selectedCol;
    // Invalidate render caches for old and new selected rows
    _rowRenderCache.remove(prevRow);
    _rowRenderCache.remove(row);
    _cellRenderCache.removeWhere((k, _) =>
        k.startsWith('$prevRow:') || k.startsWith('$row:'));
    setState(() {
      if (extend) {
        _selEndRow = row;
        _selEndCol = col;
      } else {
        _selectedRow = row;
        _selectedCol = col;
        _selEndRow = row;
        _selEndCol = col;
      }
    });
    if (scroll) _scrollToAnchor();
    // Fire selection_change if anchor moved
    if (!extend && (row != prevRow || col != prevCol)) {
      _fireSelectionChange();
    }
  }

  void _fireSelectionChange() {
    try {
      final colName = _selectedCol >= 0 && _selectedCol < _source.columnCount
          ? _source.columnName(_selectedCol) : '';
      widget.control.triggerEventWithoutSubscribers('selection_change',
          jsonEncode({
            'row': _selectedRow,
            'col': _selectedCol,
            'column_name': colName,
            'end_row': _selEndRow,
            'end_col': _selEndCol,
          }));
    } catch (_) {
      // Backend may be null in tests
    }
  }

  /// Select entire row.
  void _selectRow(int row) {
    setState(() {
      _selectedRow = row;
      _selectedCol = 0;
      _selEndRow = row;
      _selEndCol = _source.columnCount - 1;
    });
  }

  /// Select entire column.
  void _selectColumn(int col) {
    setState(() {
      _selectedRow = 0;
      _selectedCol = col;
      _selEndRow = _source.rowCount - 1;
      _selEndCol = col;
    });
  }

  /// Select all cells.
  void _selectAll() {
    setState(() {
      _selectedRow = 0;
      _selectedCol = 0;
      _selEndRow = _source.rowCount - 1;
      _selEndCol = _source.columnCount - 1;
    });
  }

  /// Get selected text as tab-separated values.
  String _getSelectionText() {
    final buf = StringBuffer();
    for (int r = _selMinRow; r <= _selMaxRow; r++) {
      for (int c = _selMinCol; c <= _selMaxCol; c++) {
        if (c > _selMinCol) buf.write('\t');
        buf.write(_source.cellText(r, c));
      }
      if (r < _selMaxRow) buf.write('\n');
    }
    return buf.toString();
  }

  // ────────────────────────────────────────────────────────────────
  // Clipboard
  // ────────────────────────────────────────────────────────────────

  void _copySelection() {
    if (_selectedRow < 0) return;
    final text = _getSelectionText();
    Clipboard.setData(ClipboardData(text: text));
  }

  void _cutSelection() {
    if (_selectedRow < 0) return;
    _copySelection();
    _clearSelection();
  }

  void _clearSelection() {
    if (!_canEdit) return;
    // Fire cell_edit with empty value for each cell in selection
    for (int r = _selMinRow; r <= _selMaxRow; r++) {
      for (int c = _selMinCol; c <= _selMaxCol; c++) {
        final colName = _source.columnName(c);
        final eventData = jsonEncode({
          'row_index': r,
          'column_name': colName,
          'old_value': _source.cellText(r, c),
          'new_value': '',
        });
        widget.control.triggerEventWithoutSubscribers('cell_edit', eventData);
      }
    }
  }

  Future<void> _pasteAtSelection() async {
    if (!_canEdit) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null || data!.text!.isEmpty) return;

    final lines = data.text!.split('\n');
    for (int r = 0; r < lines.length; r++) {
      final cols = lines[r].split('\t');
      final targetRow = _selectedRow + r;
      if (targetRow >= _source.rowCount) break;
      for (int c = 0; c < cols.length; c++) {
        final targetCol = _selectedCol + c;
        if (targetCol >= _source.columnCount) break;
        final colName = _source.columnName(targetCol);
        final eventData = jsonEncode({
          'row_index': targetRow,
          'column_name': colName,
          'old_value': _source.cellText(targetRow, targetCol),
          'new_value': cols[c],
        });
        widget.control.triggerEventWithoutSubscribers('cell_edit', eventData);
      }
    }
  }

  // ────────────────────────────────────────────────────────────────
  // Checkbox column
  // ────────────────────────────────────────────────────────────────

  void _toggleCheckbox(int row, bool checked) {
    setState(() {
      if (checked) {
        _checkedRows.add(row);
      } else {
        _checkedRows.remove(row);
      }
    });
    _fireCheckboxSelection();
  }

  void _toggleAllCheckboxes(bool checked) {
    setState(() {
      if (checked) {
        for (int i = 0; i < _source.rowCount; i++) _checkedRows.add(i);
      } else {
        _checkedRows.clear();
      }
    });
    _fireCheckboxSelection();
  }

  void _fireCheckboxSelection() {
    final eventData = jsonEncode({
      'selected_rows': _checkedRows.toList()..sort(),
    });
    widget.control.triggerEventWithoutSubscribers(
        'checkbox_selection', eventData);
  }

  // ────────────────────────────────────────────────────────────────
  // Cell editing
  // ────────────────────────────────────────────────────────────────

  bool get _canEdit {
    final editable = widget.control.getBool("editable", false) ?? false;
    if (!editable) return false;
    if (_selectedRow < 0 || _selectedCol < 0) return false;
    if (_selectedCol < _source.columns.length) {
      final readOnly = _source.columns[_selectedCol]['read_only'] ?? false;
      if (readOnly == true) return false;
    }
    return true;
  }

  void _startEditing({String? initialText, bool codeMode = false}) {
    if (!_canEdit) return;

    // Get raw value for editing (not display-formatted)
    final rawRowsJson = widget.control.getString("raw_rows");
    String rawValue = _source.cellText(_selectedRow, _selectedCol);
    if (rawRowsJson != null && rawRowsJson.isNotEmpty) {
      try {
        final rawRows = jsonDecode(rawRowsJson) as List;
        if (_selectedRow < rawRows.length) {
          final row = rawRows[_selectedRow] as List;
          if (_selectedCol < row.length && row[_selectedCol] != null) {
            rawValue = row[_selectedCol].toString();
          }
        }
      } catch (_) {}
    }

    setState(() {
      _isEditing = true;
      _isCodeMode = codeMode;
      _editOriginalValue = rawValue;
      _editValue = initialText ?? rawValue;
      _editController.text = _editValue;
      // Cursor at end of text (F2 or type-to-replace)
      _editController.selection = TextSelection.collapsed(
          offset: _editController.text.length);
    });

    // Focus the TextField on next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocusNode.requestFocus();
    });
  }

  /// Try to format a value client-side via MicroPython.
  /// Mirrors Python's _eval_display: format string fast path, then eval.
  /// Returns null if MicroPython unavailable or code fails (fall back to raw).
  /// Client-side display formatting via MicroPython _exec() contract.
  /// Runs the column's display_code with {value, row columns} as context.
  /// Returns null if MicroPython unavailable or code fails — caller
  /// falls back to raw value, Python round-trip corrects.
  String? _clientFormat(int colIndex, String rawValue) {
    if (!MicroPythonService.isReady) return null;

    final code = _source.displayCode(colIndex);
    if (code.isEmpty) return null;

    // Parse raw value to numeric for numeric columns
    dynamic value = rawValue;
    if (_source.isNumericColumn(colIndex)) {
      value = double.tryParse(rawValue) ?? int.tryParse(rawValue) ?? rawValue;
    }

    // Build context: value + other columns in the row
    final ctx = <String, dynamic>{'value': value};
    final rawRowsJson = widget.control.getString("raw_rows");
    if (rawRowsJson != null && rawRowsJson.isNotEmpty) {
      try {
        final rawRows = jsonDecode(rawRowsJson) as List;
        if (_selectedRow < rawRows.length) {
          final row = rawRows[_selectedRow] as List;
          for (int c = 0; c < row.length && c < _source.columnCount; c++) {
            ctx[_source.columnName(c)] = row[c];
          }
          ctx[_source.columnName(colIndex)] = value;
        }
      } catch (_) {}
    }

    try {
      // _exec() contract: exec all lines, return last expression.
      // Prepend "_r = str(...)" to last line so everything goes through
      // exec() — MicroPython's eval() doesn't support f-strings.
      final lines = code.trim().split('\n');
      lines[lines.length - 1] = '_r = str(${lines.last.trim()})';
      final fullCode = lines.join('\n');
      final result = MicroPythonService.execEval(fullCode, '_r', ctx);
      if (result == null) return null;
      return result.toString();
    } catch (_) {
      return null;
    }
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _isCodeMode = false;
    });
    _focusNode.requestFocus();
  }

  void _commitEdit({bool moveDown = false, bool moveRight = false,
      bool moveUp = false, bool moveLeft = false}) {
    final newValue = _editController.text;
    final oldValue = _editOriginalValue;

    setState(() {
      _isEditing = false;
      _isCodeMode = false;
    });

    // Fire on_cell_edit event if value changed
    if (newValue != oldValue) {
      // Optimistic update: try client-side MicroPython formatting first,
      // fall back to raw value. Python round-trip replaces with authoritative.
      final formatted = _clientFormat(_selectedCol, newValue);
      _pendingEdits['$_selectedRow:$_selectedCol'] = formatted ?? newValue;
      final colName = _source.columnName(_selectedCol);
      final eventData = jsonEncode({
        'row_index': _selectedRow,
        'column_name': colName,
        'old_value': oldValue,
        'new_value': newValue,
      });
      widget.control.triggerEventWithoutSubscribers('cell_edit', eventData);
    }

    // Move selection (collapse range) — scroll: false, cell is adjacent and visible
    if (moveDown && _selectedRow < _source.rowCount - 1) {
      _moveTo(_selectedRow + 1, _selectedCol, scroll: false);
    } else if (moveDown && _selectedRow == _source.rowCount - 1) {
      // Enter at last row: fire add_row event (comparison, list ctypes)
      widget.control.triggerEventWithoutSubscribers('add_row', '{}');
    } else if (moveUp && _selectedRow > 0) {
      _moveTo(_selectedRow - 1, _selectedCol, scroll: false);
    } else if (moveRight && _selectedCol < _source.columnCount - 1) {
      _moveTo(_selectedRow, _selectedCol + 1, scroll: false);
    } else if (moveLeft && _selectedCol > 0) {
      _moveTo(_selectedRow, _selectedCol - 1, scroll: false);
    }

    _focusNode.requestFocus();
  }

  // ────────────────────────────────────────────────────────────────
  // Selection + keyboard (prototype pattern)
  // ────────────────────────────────────────────────────────────────

  void _onTapDown(TapDownDetails details) {
    // Convert local position to absolute (add scroll offset)
    // In Natural mode (shrinkWrap), _yController may not be attached
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    // Subtract header height — GestureDetector wraps both header and data
    final headerH = _source.headerRowHeight;
    final dataY = details.localPosition.dy - headerH;
    if (dataY < 0) return; // tapped on header, not data
    final absY = yOffset + dataY;

    // Hit test: find column (frozen columns don't scroll horizontally)
    final frozenCount = widget.control.getInt("frozen_columns_count", 0) ?? 0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    final cbOffset = showCheckbox ? _checkboxColWidth : 0.0;
    var localX = details.localPosition.dx;
    // Skip checkbox column area — taps there handled by Checkbox widget
    if (showCheckbox && localX < cbOffset) return;
    localX -= cbOffset; // offset past checkbox for column hit test

    double absX;
    if (frozenCount > 0 && frozenCount < _source.columnCount) {
      final frozenW = _frozenColumnsWidth(frozenCount) - cbOffset; // data cols only
      if (localX <= frozenW) {
        absX = localX;
      } else {
        final xOffset = _xController.hasClients ? _xController.offset : 0.0;
        absX = frozenW + xOffset + (localX - frozenW - 2);
      }
    } else {
      final xOffset = _xController.hasClients ? _xController.offset : 0.0;
      absX = xOffset + localX;
    }

    int col = 0;
    double cumX = 0;
    for (int i = 0; i < _source.columnCount; i++) {
      final w = _getColumnWidth(i);
      if (absX >= cumX && absX < cumX + w) {
        col = i;
        break;
      }
      cumX += w;
    }

    // Hit test: find row
    int row = (absY / _source.rowHeight).floor();
    row = row.clamp(0, _source.rowCount - 1);

    // Shift+click extends selection, plain click moves anchor.
    // scroll: false — user tapped a visible cell, don't scroll.
    _moveTo(row, col,
        extend: HardwareKeyboard.instance.isShiftPressed, scroll: false);
    _focusNode.requestFocus();
  }

  /// Right-click: select cell under cursor, then show context menu.
  void _onSecondaryTapDown(TapDownDetails details) {
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    final headerH = _source.headerRowHeight;
    final dataY = details.localPosition.dy - headerH;
    if (dataY < 0) return;
    final absY = yOffset + dataY;

    final frozenCount = widget.control.getInt("frozen_columns_count", 0) ?? 0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    final cbOffset = showCheckbox ? _checkboxColWidth : 0.0;
    var localX = details.localPosition.dx;
    if (showCheckbox && localX < cbOffset) return;
    localX -= cbOffset;

    double absX;
    if (frozenCount > 0 && frozenCount < _source.columnCount) {
      final frozenW = _frozenColumnsWidth(frozenCount) - cbOffset;
      if (localX <= frozenW) {
        absX = localX;
      } else {
        final xOffset = _xController.hasClients ? _xController.offset : 0.0;
        absX = frozenW + xOffset + (localX - frozenW - 2);
      }
    } else {
      final xOffset = _xController.hasClients ? _xController.offset : 0.0;
      absX = xOffset + localX;
    }

    int col = 0;
    double cumX = 0;
    for (int i = 0; i < _source.columnCount; i++) {
      final w = _getColumnWidth(i);
      if (absX >= cumX && absX < cumX + w) {
        col = i;
        break;
      }
      cumX += w;
    }
    int row = (absY / _source.rowHeight).floor();
    row = row.clamp(0, _source.rowCount - 1);

    if (!_isInSelection(row, col)) {
      _moveTo(row, col, scroll: false);
    }
    _focusNode.requestFocus();

    _showContextMenu(details.globalPosition, row, col);
  }

  /// Show right-click context menu (CM1-CM6, ctype-aware).
  void _showContextMenu(Offset globalPosition, int row, int col) {
    final hasOverride = _source.hasOverride(row, col);
    final editable = _canEdit;
    final allowDeleteRow =
        widget.control.getBool("allow_delete_row", true) ?? true;
    final allowInsertRow =
        widget.control.getBool("allow_insert_row", true) ?? true;
    final allowOverride =
        widget.control.getBool("allow_override", true) ?? true;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx, globalPosition.dy,
        globalPosition.dx, globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
        if (editable)
          const PopupMenuItem(value: 'cut', child: Text('Cut')),
        if (editable)
          const PopupMenuItem(value: 'paste', child: Text('Paste')),
        if (editable) const PopupMenuDivider(),
        if (editable)
          const PopupMenuItem(value: 'clear', child: Text('Clear')),
        if (editable && allowInsertRow)
          PopupMenuItem(value: 'insert_row',
              child: Text('Insert Row Above')),
        if (editable && allowDeleteRow)
          PopupMenuItem(value: 'delete_row',
              child: Text('Delete Row')),
        if (editable && allowOverride && hasOverride)
          const PopupMenuDivider(),
        if (editable && allowOverride && hasOverride)
          PopupMenuItem(
            value: 'remove_override',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.close, size: 14, color: Colors.orange.shade400),
                const SizedBox(width: 6),
                const Text('Remove Override'),
              ],
            ),
          ),
      ],
    ).then((action) {
      if (action == null) return;
      switch (action) {
        case 'copy':
          _copySelection();
          break;
        case 'cut':
          _cutSelection();
          break;
        case 'paste':
          _pasteAtSelection();
          break;
        case 'clear':
          _clearSelection();
          break;
        case 'insert_row':
        case 'delete_row':
        case 'remove_override':
          final colName = _source.columnName(col);
          final eventData = jsonEncode({
            'action': action,
            'row_index': row,
            'column_name': colName,
          });
          widget.control.triggerEventWithoutSubscribers(
              'context_action', eventData);
          break;
      }
    });
  }

  /// Show right-click context menu on column header (CM5).
  void _showHeaderContextMenu(Offset globalPosition, int col) {
    final allowSorting =
        widget.control.getBool("allow_sorting", false) ?? false;
    final colName = _source.columnName(col);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx, globalPosition.dy,
        globalPosition.dx, globalPosition.dy,
      ),
      items: [
        if (allowSorting)
          PopupMenuItem(value: 'sort_asc',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.arrow_upward, size: 14),
                const SizedBox(width: 6),
                const Text('Sort Ascending'),
              ])),
        if (allowSorting)
          PopupMenuItem(value: 'sort_desc',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.arrow_downward, size: 14),
                const SizedBox(width: 6),
                const Text('Sort Descending'),
              ])),
        if (allowSorting) const PopupMenuDivider(),
        PopupMenuItem(value: 'auto_fit',
            child: Text('Auto-Fit Width')),
        PopupMenuItem(value: 'hide_column',
            child: Text('Hide Column')),
      ],
    ).then((action) {
      if (action == null) return;
      switch (action) {
        case 'sort_asc':
          widget.control.triggerEventWithoutSubscribers(
              'sort_request', jsonEncode({'column': colName, 'ascending': true}));
          break;
        case 'sort_desc':
          widget.control.triggerEventWithoutSubscribers(
              'sort_request', jsonEncode({'column': colName, 'ascending': false}));
          break;
        case 'auto_fit':
          _autoSizeColumn(col);
          break;
        case 'hide_column':
          widget.control.triggerEventWithoutSubscribers(
              'context_action', jsonEncode({'action': 'hide_column', 'column_name': colName}));
          break;
      }
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_sourceInitialized) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // When editing, the TextField handles most keys.
    // We intercept: Enter, Tab, Shift+Tab, Escape, arrow up/down
    if (_isEditing) {
      if (key == LogicalKeyboardKey.escape) {
        _cancelEdit();
        return KeyEventResult.handled;
      }
      // Ctrl+Enter: commit without moving
      if (key == LogicalKeyboardKey.enter &&
          (HardwareKeyboard.instance.isControlPressed ||
           HardwareKeyboard.instance.isMetaPressed)) {
        _commitEdit();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _commitEdit(moveDown: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter &&
          HardwareKeyboard.instance.isShiftPressed) {
        _commitEdit(moveUp: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _commitEdit(moveRight: true);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab &&
          HardwareKeyboard.instance.isShiftPressed) {
        _commitEdit(moveLeft: true);
        return KeyEventResult.handled;
      }
      // Let TextField handle everything else (typing, arrow left/right, etc.)
      return KeyEventResult.ignored;
    }

    // Not editing — navigation and edit-start keys
    bool handled = false;
    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    // -- Clipboard shortcuts --
    if (isCtrl && key == LogicalKeyboardKey.keyC) {
      _copySelection();
      handled = true;
    } else if (isCtrl && key == LogicalKeyboardKey.keyX) {
      _cutSelection();
      handled = true;
    } else if (isCtrl && key == LogicalKeyboardKey.keyV) {
      _pasteAtSelection();
      handled = true;
    } else if (isCtrl && key == LogicalKeyboardKey.keyA) {
      _selectAll();
      handled = true;
    } else if (isCtrl && key == LogicalKeyboardKey.keyZ) {
      widget.control.triggerEventWithoutSubscribers('undo', '{}');
      handled = true;
    } else if (isCtrl && key == LogicalKeyboardKey.keyY) {
      widget.control.triggerEventWithoutSubscribers('redo', '{}');
      handled = true;

    // -- Ctrl+Enter: commit without moving --
    } else if (isCtrl && key == LogicalKeyboardKey.enter) {
      // Ctrl+Enter when not editing: no-op. When editing: handled above.
      handled = true;

    // -- Ctrl+Backspace: scroll to active cell --
    } else if (isCtrl && key == LogicalKeyboardKey.backspace) {
      _scrollToAnchor();
      handled = true;

    // -- Shift+Space: select row --
    } else if (isShift && key == LogicalKeyboardKey.space) {
      _selectRow(_selectedRow);
      handled = true;

    // -- Ctrl+Space: select column --
    } else if (isCtrl && key == LogicalKeyboardKey.space) {
      _selectColumn(_selectedCol);
      handled = true;

    // -- Arrow keys (with Ctrl+Shift, Ctrl, Shift, plain) --
    } else if (key == LogicalKeyboardKey.arrowDown) {
      final targetRow = isCtrl ? _source.rowCount - 1
          : (isShift ? _selEndRow + 1 : _selectedRow + 1);
      final row = targetRow.clamp(0, _source.rowCount - 1);
      if (isShift) {
        setState(() => _selEndRow = row);
      } else if (isCtrl) {
        // Ctrl+Down: jump to last row
        _moveTo(row, _selectedCol, scroll: false);
        _scrollToEdge(bottom: true);
      } else {
        // Single step: delta scroll only if target not visible
        if (!_isRowVisible(row) && _yController.hasClients) {
          _yController.jumpTo(
              (_yController.offset + _source.rowHeight)
                  .clamp(0.0, _yController.position.maxScrollExtent));
        }
        _moveTo(row, _selectedCol, scroll: false);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final targetRow = isCtrl ? 0
          : (isShift ? _selEndRow - 1 : _selectedRow - 1);
      final row = targetRow.clamp(0, _source.rowCount - 1);
      if (isShift) {
        setState(() => _selEndRow = row);
      } else if (isCtrl) {
        // Ctrl+Up: jump to first row
        _moveTo(row, _selectedCol, scroll: false);
        _scrollToEdge(bottom: false);
      } else {
        // Single step: delta scroll only if target not visible
        if (!_isRowVisible(row) && _yController.hasClients) {
          _yController.jumpTo(
              (_yController.offset - _source.rowHeight)
                  .clamp(0.0, _yController.position.maxScrollExtent));
        }
        _moveTo(row, _selectedCol, scroll: false);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      final targetCol = isCtrl ? _source.columnCount - 1
          : (isShift ? _selEndCol + 1 : _selectedCol + 1);
      final col = targetCol.clamp(0, _source.columnCount - 1);
      if (isShift) {
        setState(() => _selEndCol = col);
      } else {
        // Only scroll if target column is not already visible
        if (!_isColumnVisible(col) && _xController.hasClients) {
          if (col > _selectedCol) {
            _xController.jumpTo(
                (_xController.offset + _getColumnWidth(_selectedCol))
                    .clamp(0.0, _xController.position.maxScrollExtent));
          } else {
            _xController.jumpTo(
                (_xController.offset - _getColumnWidth(col))
                    .clamp(0.0, _xController.position.maxScrollExtent));
          }
        }
        _moveTo(_selectedRow, col, scroll: false);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final targetCol = isCtrl ? 0
          : (isShift ? _selEndCol - 1 : _selectedCol - 1);
      final col = targetCol.clamp(0, _source.columnCount - 1);
      if (isShift) {
        setState(() => _selEndCol = col);
      } else {
        // Only scroll if target column is not already visible
        if (!_isColumnVisible(col) && _xController.hasClients) {
          if (col < _selectedCol) {
            _xController.jumpTo(
                (_xController.offset - _getColumnWidth(col))
                    .clamp(0.0, _xController.position.maxScrollExtent));
          } else {
            _xController.jumpTo(
                (_xController.offset + _getColumnWidth(_selectedCol))
                    .clamp(0.0, _xController.position.maxScrollExtent));
          }
        }
        _moveTo(_selectedRow, col, scroll: false);
      }
      handled = true;

    // -- Home/End --
    } else if (key == LogicalKeyboardKey.home && isCtrl) {
      _moveTo(0, 0, extend: isShift);
      handled = true;
    } else if (key == LogicalKeyboardKey.end && isCtrl) {
      final lastRow = _source.rowCount - 1;
      final lastCol = _source.columnCount - 1;
      _moveTo(lastRow, lastCol, extend: isShift);
      handled = true;
    } else if (key == LogicalKeyboardKey.home) {
      if (isShift) {
        setState(() => _selEndCol = 0);
        _scrollToSelEnd();
      } else {
        _moveTo(_selectedRow, 0);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.end) {
      final lastCol = _source.columnCount - 1;
      if (isShift) {
        setState(() => _selEndCol = lastCol);
        _scrollToSelEnd();
      } else {
        _moveTo(_selectedRow, lastCol);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.pageDown) {
      final visibleRows = _yController.hasClients
          ? (_yController.position.viewportDimension / _source.rowHeight).floor()
          : 10;
      final row = (_selectedRow + visibleRows).clamp(0, _source.rowCount - 1);
      _moveTo(row, _selectedCol);
      handled = true;
    } else if (key == LogicalKeyboardKey.pageUp) {
      final visibleRows = _yController.hasClients
          ? (_yController.position.viewportDimension / _source.rowHeight).floor()
          : 10;
      final row = (_selectedRow - visibleRows).clamp(0, _source.rowCount - 1);
      _moveTo(row, _selectedCol);
      handled = true;
    } else if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      // Delete/Backspace: clear selection
      if (_canEdit) {
        _clearSelection();
        handled = true;
      }
    } else if (key == LogicalKeyboardKey.escape) {
      // Escape: collapse range selection back to anchor
      if (_hasRange) {
        _moveTo(_selectedRow, _selectedCol);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.f2) {
      // F2: edit current cell (cursor at end)
      _startEditing();
      handled = true;
    } else if (key == LogicalKeyboardKey.enter) {
      // Enter when not editing: start editing
      _startEditing();
      handled = true;
    } else {
      // Character keys: check event.character for printable input
      final char = event.character;
      if (char != null && char.length == 1) {
        if (char.codeUnitAt(0) >= 0x20) {
          // Any printable character (>= space): type-to-replace
          _startEditing(initialText: char);
          handled = true;
        }
      }
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Fire column_resize event to Python for persistence.
  void _fireColumnResize(int col) {
    final colName = _source.columnName(col);
    final w = _getColumnWidth(col);
    widget.control.triggerEventWithoutSubscribers(
        'column_resize', jsonEncode({'column': colName, 'width': w}));
  }

  /// Auto-size column to fit widest content (double-click on resize handle).
  void _autoSizeColumn(int col) {
    // Measure widest cell text in this column
    final style = TextStyle(
      fontSize: _source.cellFontSize,
      fontFamily: _source.fontFamily,
    );
    double maxWidth = 60.0; // minimum
    for (int r = 0; r < _source.rowCount; r++) {
      final text = _source.cellText(r, col);
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > maxWidth) maxWidth = tp.width;
    }
    // Add padding
    maxWidth += _source.cellPaddingH * 2 + 8;
    setState(() => _columnWidthOverrides[col] = maxWidth.clamp(40.0, 4000.0));
    _fireColumnResize(col);
  }

  /// Is column `col` fully visible in the horizontal viewport?
  bool _isColumnVisible(int col) {
    if (!_xController.hasClients) return true;
    double colLeft = 0;
    for (int i = 0; i < col; i++) colLeft += _getColumnWidth(i);
    final colRight = colLeft + _getColumnWidth(col);
    final offset = _xController.offset;
    final vw = _xController.position.viewportDimension;
    return colLeft >= offset && colRight <= offset + vw;
  }

  /// Is row `row` fully visible in the vertical viewport?
  bool _isRowVisible(int row) {
    if (!_yController.hasClients) return true;
    final rowTop = row * _source.rowHeight;
    final rowBottom = rowTop + _source.rowHeight;
    final offset = _yController.offset;
    final vh = _yController.position.viewportDimension;
    return rowTop >= offset && rowBottom <= offset + vh;
  }

  /// Column width: use drag override if set, else source default.
  double _getColumnWidth(int i) {
    return _columnWidthOverrides[i] ?? _source.columnWidth(i);
  }

  /// Total width of all columns including drag overrides, excluding hidden.
  double get _totalColumnsWidth {
    double total = 0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    if (showCheckbox) total += _checkboxColWidth;
    for (int i = 0; i < _source.columnCount; i++) {
      if (!_source.isColumnHidden(i)) total += _getColumnWidth(i);
    }
    return total;
  }

  /// Width of frozen columns (first N visible columns).
  double _frozenColumnsWidth(int frozenCount) {
    double total = 0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    if (showCheckbox) total += _checkboxColWidth;
    for (int i = 0; i < frozenCount && i < _source.columnCount; i++) {
      if (!_source.isColumnHidden(i)) total += _getColumnWidth(i);
    }
    return total;
  }

  /// Width of scrollable columns (after frozen), excluding hidden.
  double _scrollableColumnsWidth(int frozenCount) {
    double total = 0;
    for (int i = frozenCount; i < _source.columnCount; i++) {
      if (!_source.isColumnHidden(i)) total += _getColumnWidth(i);
    }
    return total;
  }

  void _ensureRowVisible(int row) {
    // In Natural mode, _yController has no clients (shrinkWrap ListView)
    if (!_yController.hasClients) return;
    final offset = row * _source.rowHeight;
    final viewportHeight = _yController.position.viewportDimension;
    if (offset < _yController.offset) {
      _yController.jumpTo(offset);
    } else if (offset + _source.rowHeight >
        _yController.offset + viewportHeight) {
      _yController.jumpTo(offset + _source.rowHeight - viewportHeight);
    }
  }

  /// Scroll to top or bottom edge. Works in both bounded and Natural mode.
  /// Bounded: uses _yController. Natural: uses parent Scrollable directly.
  void _scrollToEdge({required bool bottom}) {
    if (_yController.hasClients) {
      // Bounded mode
      _yController.jumpTo(
          bottom ? _yController.position.maxScrollExtent : 0.0);
    } else {
      // Natural mode: row widget may not be built yet (off-screen).
      // Scroll the parent scrollable directly to the edge.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final position = Scrollable.maybeOf(context)?.position;
        if (position != null) {
          position.jumpTo(
              bottom ? position.maxScrollExtent : 0.0);
        }
      });
    }
  }

  // ────────────────────────────────────────────────────────────────
  // Hover tracking + scriptable cell painting (§6A render_code)
  // ────────────────────────────────────────────────────────────────

  void _onHover(Offset localPosition) {
    final headerH = _source.headerRowHeight;
    final dataY = localPosition.dy - headerH;
    if (dataY < 0) {
      if (_hoveredRow != -1) {
        final old = _hoveredRow;
        setState(() {
          _hoveredRow = -1;
          _hoveredCol = -1;
          _rowRenderCache.remove(old);
          _cellRenderCache.removeWhere((k, _) => k.startsWith('$old:'));
        });
      }
      return;
    }
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    final xOffset = _xController.hasClients ? _xController.offset : 0.0;
    final row = ((yOffset + dataY) / _source.rowHeight).floor().clamp(0, _source.rowCount - 1);

    // Hit-test column (-1 if past last column)
    final absX = xOffset + localPosition.dx;
    int col = -1;
    double cumX = 0;
    for (int i = 0; i < _source.columnCount; i++) {
      final w = _getColumnWidth(i);
      if (absX >= cumX && absX < cumX + w) { col = i; break; }
      cumX += w;
    }

    // If past last column (empty space), treat as no-hover
    if (col == -1) {
      if (_hoveredRow != -1) {
        final old = _hoveredRow;
        setState(() {
          _hoveredRow = -1;
          _hoveredCol = -1;
          _rowRenderCache.remove(old);
          _cellRenderCache.removeWhere((k, _) => k.startsWith('$old:'));
        });
      }
      return;
    }

    if (row != _hoveredRow || col != _hoveredCol) {
      final oldRow = _hoveredRow;
      setState(() {
        _hoveredRow = row;
        _hoveredCol = col;
        _rowRenderCache.remove(oldRow);
        _rowRenderCache.remove(row);
        _cellRenderCache.removeWhere(
            (k, _) => k.startsWith('$oldRow:') || k.startsWith('$row:'));
      });
    }
  }

  void _onHoverExit() {
    if (_hoveredRow != -1) {
      final oldHover = _hoveredRow;
      setState(() {
        _hoveredRow = -1;
        _rowRenderCache.remove(oldHover);
        _cellRenderCache.removeWhere(
            (k, _) => k.startsWith('$oldHover:'));
      });
    }
  }

  /// Evaluate row_render_code for a row via MicroPython.
  /// Returns {bg} dict or null. Cached per-row.
  Map<String, String>? _evalRowRender(int rowIndex) {
    final code = widget.control.getString("row_render_code") ?? '';
    if (code.isEmpty || !MicroPythonService.isReady) return null;

    // Cache check
    if (_rowRenderCache.containsKey(rowIndex)) {
      return _rowRenderCache[rowIndex];
    }

    final visibleRows = _yController.hasClients
        ? (_yController.position.viewportDimension / _source.rowHeight).floor()
        : _source.visibleRowEstimate;
    final vpPos = _yController.hasClients
        ? rowIndex - (_yController.offset / _source.rowHeight).floor()
        : rowIndex;

    final ctx = <String, dynamic>{
      'viewport_pos': vpPos,
      'viewport_count': visibleRows,
      'row_index': rowIndex,
      'is_selected': rowIndex == _selectedRow,
      'is_hovered': rowIndex == _hoveredRow,
      'existing_bg': _source.rowBackground(rowIndex, rowIndex == _selectedRow)
          ?.toString(),
    };

    try {
      final lines = code.trim().split('\n');
      lines[lines.length - 1] = '_r = ${lines.last.trim()}';
      final fullCode = lines.join('\n');
      final result = MicroPythonService.execEval(fullCode, '_r', ctx);
      if (result is Map) {
        final style = <String, String>{};
        if (result['bg'] != null) style['bg'] = result['bg'].toString();
        if (result['fg'] != null) style['fg'] = result['fg'].toString();
        _rowRenderCache[rowIndex] = style.isEmpty ? null : style;
        return _rowRenderCache[rowIndex];
      }
    } catch (_) {}
    _rowRenderCache[rowIndex] = null;
    return null;
  }

  /// Evaluate render_code for a cell via MicroPython.
  /// Returns {bg, fg} dict or null. Cached per-cell.
  Map<String, String>? _evalCellRender(int rowIndex, int colIndex) {
    final code = widget.control.getString("render_code") ?? '';
    if (code.isEmpty || !MicroPythonService.isReady) return null;

    final key = '$rowIndex:$colIndex';
    if (_cellRenderCache.containsKey(key)) {
      return _cellRenderCache[key];
    }

    final visibleRows = _yController.hasClients
        ? (_yController.position.viewportDimension / _source.rowHeight).floor()
        : _source.visibleRowEstimate;
    final vpPos = _yController.hasClients
        ? rowIndex - (_yController.offset / _source.rowHeight).floor()
        : rowIndex;

    final cellStyle = _source.cellStyle(rowIndex, colIndex);
    final ctx = <String, dynamic>{
      'viewport_pos': vpPos,
      'viewport_count': visibleRows,
      'row_index': rowIndex,
      'col_index': colIndex,
      'col_name': colIndex < _source.columnCount
          ? _source.columnName(colIndex) : '',
      'is_selected': _isInSelection(rowIndex, colIndex),
      'is_hovered': rowIndex == _hoveredRow,
      'is_hovered_cell': rowIndex == _hoveredRow && colIndex == _hoveredCol,
      'hovered_col': _hoveredCol,
      'existing_bg': cellStyle?['bg'],
      'existing_fg': cellStyle?['fg'],
    };

    try {
      final lines = code.trim().split('\n');
      lines[lines.length - 1] = '_r = ${lines.last.trim()}';
      final fullCode = lines.join('\n');
      final result = MicroPythonService.execEval(fullCode, '_r', ctx);
      if (result is Map) {
        final style = <String, String>{};
        if (result['bg'] != null) style['bg'] = result['bg'].toString();
        if (result['fg'] != null) style['fg'] = result['fg'].toString();
        _cellRenderCache[key] = style.isEmpty ? null : style;
        return _cellRenderCache[key];
      }
    } catch (_) {}
    _cellRenderCache[key] = null;
    return null;
  }

  /// Invalidate all render caches (on data change, script change).
  void _invalidateRenderCaches() {
    _rowRenderCache.clear();
    _cellRenderCache.clear();
  }

  void _ensureColumnVisible(int col) {
    if (!_xController.hasClients) return;
    // Calculate column's left offset
    double colLeft = 0;
    for (int i = 0; i < col; i++) {
      colLeft += _getColumnWidth(i);
    }
    final colRight = colLeft + _getColumnWidth(col);
    final viewportWidth = _xController.position.viewportDimension;
    final offset = _xController.offset;
    if (colLeft < offset) {
      _xController.jumpTo(colLeft);
    } else if (colRight > offset + viewportWidth) {
      _xController.jumpTo(colRight - viewportWidth);
    }
  }

  /// Scroll the anchor cell into view.
  /// Bounded mode: direct jumpTo on controllers (math-based, works with virtualization).
  /// Natural mode: Scrollable.ensureVisible on the row widget (scrolls parent pane).
  void _scrollToAnchor() {
    _ensureRowVisible(_selectedRow);
    _ensureColumnVisible(_selectedCol);
    _ensureRowVisibleNatural();
  }

  /// Scroll the selection-end cell into view (for Shift+Arrow).
  void _scrollToSelEnd() {
    _ensureRowVisible(_selEndRow);
    _ensureColumnVisible(_selEndCol);
    _ensureRowVisibleNatural();
  }

  /// Previous selected row — used to determine scroll direction in Natural mode.
  int _prevSelectedRow = -1;

  /// Natural mode: scroll the selected row into view via parent scrollable.
  /// Picks alignment policy based on direction: keepVisibleAtEnd for downward
  /// movement, keepVisibleAtStart for upward, so we scroll minimally.
  void _ensureRowVisibleNatural() {
    if (_yController.hasClients) return; // bounded mode handled above
    final goingDown = _selectedRow >= _prevSelectedRow;
    _prevSelectedRow = _selectedRow;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedRowKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          duration: Duration.zero,
          alignmentPolicy: goingDown
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
  }

  // ────────────────────────────────────────────────────────────────
  // Sort (header tap → event to Python)
  // ────────────────────────────────────────────────────────────────

  void _onHeaderTap(int colIndex) {
    final allowSorting =
        widget.control.getBool("allow_sorting", false) ?? false;
    if (!allowSorting) return;

    final colName = _source.columnName(colIndex);
    final eventData = jsonEncode({
      "column": colName,
      "ascending": true, // TODO: toggle asc/desc/none
    });
    widget.control
        .triggerEventWithoutSubscribers("sort_request", eventData);
  }

  // ────────────────────────────────────────────────────────────────
  // Helpers
  // ────────────────────────────────────────────────────────────────

  double _rowNumberWidth() {
    final totalRows =
        widget.control.getInt("total_rows", 0) ?? _source.rowCount;
    final digits = totalRows > 0
        ? (math.log(totalRows) / math.ln10).floor() + 1
        : 1;
    return (digits * 9.0 + 16).clamp(40.0, 100.0);
  }

  /// Get or create a ScrollController synced to _yController for row numbers.
  ScrollController _getRowNumController() {
    if (_yRowNumController == null) {
      _yRowNumController = ScrollController();
      _yController.addListener(() {
        if (_yController.hasClients &&
            _yRowNumController!.hasClients &&
            _yRowNumController!.offset != _yController.offset) {
          _yRowNumController!.jumpTo(_yController.offset);
        }
      });
    }
    return _yRowNumController!;
  }

  /// Get or create a ScrollController synced to _yController for frozen columns.
  ScrollController _getFrozenController() {
    if (_yFrozenController == null) {
      _yFrozenController = ScrollController();
      // Bidirectional sync: frozen ↔ main
      bool syncing = false;
      _yController.addListener(() {
        if (syncing) return;
        if (_yController.hasClients &&
            _yFrozenController!.hasClients &&
            _yFrozenController!.offset != _yController.offset) {
          syncing = true;
          _yFrozenController!.jumpTo(_yController.offset);
          syncing = false;
        }
      });
      _yFrozenController!.addListener(() {
        if (syncing) return;
        if (_yFrozenController!.hasClients &&
            _yController.hasClients &&
            _yController.offset != _yFrozenController!.offset) {
          syncing = true;
          _yController.jumpTo(_yFrozenController!.offset);
          syncing = false;
        }
      });
    }
    return _yFrozenController!;
  }

  static Color? _parseHexColor(String hex) {
    if (hex.isEmpty) return null;
    hex = hex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    try {
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return null;
    }
  }
}

/// Paints a small orange triangle in the top-left corner of a cell
/// to indicate the cell has a user override.
class _OverrideTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.fill;
    const double s = 6;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(s, 0)
      ..lineTo(0, s)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Paints a solid background colour up to [maxBgWidth] pixels and an optional
/// right-aligned [rightText] label (row position) within that bar width.
class _BarBgPainter extends CustomPainter {
  final Color color;
  final double maxBgWidth;
  final String rightText;
  _BarBgPainter(this.color, this.maxBgWidth, [this.rightText = '']);

  @override
  void paint(Canvas canvas, Size size) {
    final w = maxBgWidth > 0 ? math.min(maxBgWidth, size.width) : size.width;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, size.height), Paint()..color = color);

    if (rightText.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: rightText,
          style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w - tp.width - 8, (size.height - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BarBgPainter old) =>
      color != old.color || maxBgWidth != old.maxBgWidth ||
      rightText != old.rightText;
}

