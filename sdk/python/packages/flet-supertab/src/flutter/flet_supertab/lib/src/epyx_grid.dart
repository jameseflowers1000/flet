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
  final ScrollController _yController = ScrollController();
  final ScrollController _xController = ScrollController();
  final ScrollController _xHeaderController = ScrollController();
  ScrollController? _yRowNumController;

  // -- Selection state --
  int _selectedRow = -1;
  int _selectedCol = -1;

  // -- Scroll tracking for header display --
  int _firstVisibleRow = 0;

  // -- Focus node for keyboard handling --
  late FocusNode _focusNode;

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
    _focusNode.dispose();
    super.dispose();
  }

  void _onControlChanged() {
    if (mounted) {
      setState(() {
        _sourceNeedsRebuild = true;
      });
    }
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
      getIsEditing: () => false, // P1: no editing
      getVisibleRowCount: () {
        if (!_yController.hasClients) return 0;
        return (_yController.position.viewportDimension / _source.rowHeight)
            .floor();
      },
      getFirstVisibleRow: () => _firstVisibleRow,
      simulateTap: (row, col) {
        setState(() {
          _selectedRow = row;
          _selectedCol = col;
        });
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

    // -- Grid body --
    final gridBody = _source.rowCount == 0
        ? const Center(
            child: Text("No data",
                style: TextStyle(color: Colors.grey, fontSize: 14)))
        : _buildGridBody(context);

    final result = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        headerBar,
        // Error banner (R14)
        if (errorMessage.isNotEmpty)
          Container(
            color: Colors.red.shade900,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(errorMessage,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          ),
        Expanded(child: gridBody),
      ],
    );

    return LayoutControl(control: widget.control, child: result);
  }

  // ────────────────────────────────────────────────────────────────
  // Header bar (H1-H5)
  // ────────────────────────────────────────────────────────────────

  Widget _buildHeaderBar(String label, String ctype, String sortIndicator,
      bool filterActive, String rowPositionText, BuildContext context) {
    final headerBg =
        _color("header_bg_color", context, const Color(0xFF2D2D30));

    return Container(
      color: headerBg,
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
          const Spacer(),
          // H3: Row position
          Text(rowPositionText,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Grid body: column headers + SliverList rows
  // ────────────────────────────────────────────────────────────────

  Widget _buildGridBody(BuildContext context) {
    final showRowNumbers =
        widget.control.getBool("show_row_numbers", false) ?? false;
    final rowNumWidth = showRowNumbers ? _rowNumberWidth() : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Set available width for last-column-fill calculation
        final dataWidth = constraints.maxWidth - rowNumWidth;
        _source.setAvailableWidth(dataWidth);

        return Column(
          children: [
            // Column headers
            _buildColumnHeaders(context, showRowNumbers, rowNumWidth),
            // Data rows
            Expanded(
              child: _buildDataArea(context, showRowNumbers, rowNumWidth),
            ),
          ],
        );
      },
    );
  }

  /// Column header row — synced horizontally with body.
  Widget _buildColumnHeaders(
      BuildContext context, bool showRowNumbers, double rowNumWidth) {
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

    return Container(
      height: headerRowHeight,
      color: headerBg,
      child: Row(
        children: [
          // Row number header placeholder
          if (showRowNumbers)
            Container(
              width: rowNumWidth,
              height: headerRowHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                      color: _source.gridLineColor,
                      width: _source.gridLineWidth),
                ),
              ),
              child: Text("#",
                  style: TextStyle(
                      color: headerTextColor.withValues(alpha: 0.6),
                      fontSize: headerFontSize - 1)),
            ),
          // Column headers (scrollable, synced with body)
          Expanded(
            child: SingleChildScrollView(
              controller: _xHeaderController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  for (int i = 0; i < _source.columnCount; i++)
                    GestureDetector(
                      onTap: () => _onHeaderTap(i),
                      child: Container(
                        width: _source.columnWidth(i),
                        height: headerRowHeight,
                        padding:
                            EdgeInsets.symmetric(horizontal: headerPadH),
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
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Data area: row numbers + scrollable cells.
  Widget _buildDataArea(
      BuildContext context, bool showRowNumbers, double rowNumWidth) {
    return Row(
      children: [
        // Row numbers column (fixed, scrolls vertically with body)
        if (showRowNumbers) _buildRowNumberColumn(rowNumWidth),
        // Main data grid
        Expanded(child: _buildScrollableGrid(context)),
      ],
    );
  }

  /// Row number column — syncs vertically with data body.
  Widget _buildRowNumberColumn(double width) {
    return SizedBox(
      width: width,
      child: CustomScrollView(
        controller: _getRowNumController(),
        physics: const NeverScrollableScrollPhysics(),
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                return Container(
                  height: _source.rowHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                          color: _source.gridLineColor,
                          width: _source.gridLineWidth),
                      right: BorderSide(
                          color: _source.gridLineColor,
                          width: _source.gridLineWidth),
                    ),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: _source.cellFontSize - 1),
                  ),
                );
              },
              childCount: _source.rowCount,
            ),
          ),
        ],
      ),
    );
  }

  /// Main scrollable grid.
  /// Uses LayoutBuilder to detect bounded vs unbounded height constraints:
  /// - Bounded (Gallery/Fit mode): ListView.builder with virtualization
  /// - Unbounded (Natural mode): shrinkWrap ListView (no virtualization,
  ///   but renders correctly without explicit height)
  Widget _buildScrollableGrid(BuildContext context) {
    final totalRows = widget.control.getInt("total_rows", 0) ?? 0;
    final hasMore = totalRows > _source.rowCount;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: GestureDetector(
        onTapDown: (details) => _onTapDown(details),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final unboundedHeight = constraints.maxHeight == double.infinity;

            return SingleChildScrollView(
              controller: _xController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: SizedBox(
                width: _source.totalColumnsWidth,
                child: ListView.builder(
                  controller: unboundedHeight ? null : _yController,
                  shrinkWrap: unboundedHeight,
                  physics: unboundedHeight
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  itemCount: _source.rowCount + (hasMore ? 1 : 0),
                  itemExtent: _source.rowHeight,
                  itemBuilder: (context, index) {
                    if (index >= _source.rowCount) {
                      // LOD: request next page when spinner is built
                      _requestNextPage();
                      return const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return _buildRow(index);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

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

  Widget _buildRow(int rowIndex) {
    final isSelected = rowIndex == _selectedRow;

    return Container(
      height: _source.rowHeight,
      decoration: BoxDecoration(
        color: _source.rowBackground(rowIndex, isSelected),
        border: Border(
          bottom: BorderSide(
              color: _source.gridLineColor, width: _source.gridLineWidth),
        ),
      ),
      child: Row(
        children: [
          for (int colIndex = 0; colIndex < _source.columnCount; colIndex++)
            _buildCell(rowIndex, colIndex),
        ],
      ),
    );
  }

  Widget _buildCell(int rowIndex, int colIndex) {
    final isSelected =
        rowIndex == _selectedRow && colIndex == _selectedCol;
    final cellText = _source.cellText(rowIndex, colIndex);
    final cellStyle = _source.cellStyle(rowIndex, colIndex);

    Color? fg = cellStyle?['fg'] != null
        ? _parseHexColor(cellStyle!['fg']!)
        : null;
    Color? bg = cellStyle?['bg'] != null
        ? _parseHexColor(cellStyle!['bg']!)
        : null;

    final textColor = fg ?? _source.cellTextColor;
    final bgColor = bg;

    return Semantics(
      label: 'cell_${rowIndex}_${colIndex}_$cellText',
      child: Container(
        width: _source.columnWidth(colIndex),
        height: _source.rowHeight,
        padding: EdgeInsets.symmetric(
          horizontal: _source.cellPaddingH,
          vertical: _source.cellPaddingV,
        ),
        alignment: _source.isNumericColumn(colIndex)
            ? Alignment.centerRight
            : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: bgColor,
          border: isSelected
              ? Border.all(
                  color: _source.currentCellBorderColor,
                  width: _source.currentCellBorderWidth,
                )
              : Border(
                  right: BorderSide(
                      color: _source.gridLineColor,
                      width: _source.gridLineWidth),
                ),
        ),
        child: Text(
          cellText,
          style: TextStyle(
            color: textColor == Colors.transparent ? null : textColor,
            fontSize: _source.cellFontSize,
            fontFamily: _source.fontFamily,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Selection + keyboard (prototype pattern)
  // ────────────────────────────────────────────────────────────────

  void _onTapDown(TapDownDetails details) {
    // Convert local position to absolute (add scroll offset)
    final absX = _xController.offset + details.localPosition.dx;
    final absY = _yController.offset + details.localPosition.dy;

    // Hit test: find column
    int col = 0;
    double cumX = 0;
    for (int i = 0; i < _source.columnCount; i++) {
      final w = _source.columnWidth(i);
      if (absX >= cumX && absX < cumX + w) {
        col = i;
        break;
      }
      cumX += w;
    }

    // Hit test: find row
    int row = (absY / _source.rowHeight).floor();
    row = row.clamp(0, _source.rowCount - 1);

    setState(() {
      _selectedRow = row;
      _selectedCol = col;
    });
    _focusNode.requestFocus();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    bool handled = false;

    if (key == LogicalKeyboardKey.arrowDown) {
      if (_selectedRow < _source.rowCount - 1) {
        setState(() => _selectedRow++);
        _ensureRowVisible(_selectedRow);
        handled = true;
      }
    } else if (key == LogicalKeyboardKey.arrowUp) {
      if (_selectedRow > 0) {
        setState(() => _selectedRow--);
        _ensureRowVisible(_selectedRow);
        handled = true;
      }
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (_selectedCol < _source.columnCount - 1) {
        setState(() => _selectedCol++);
        handled = true;
      }
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (_selectedCol > 0) {
        setState(() => _selectedCol--);
        handled = true;
      }
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _ensureRowVisible(int row) {
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
        if (_yRowNumController!.hasClients &&
            _yRowNumController!.offset != _yController.offset) {
          _yRowNumController!.jumpTo(_yController.offset);
        }
      });
    }
    return _yRowNumController!;
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
