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
import 'package:flet_micropython/flet_micropython.dart' show RenderPlaneControl;
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:flutter/services.dart';


import 'epyx_grid_cache.dart';
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
  // -- Pixel-space LOD cache --
  final GridCache _cache = GridCache();
  int _lastDataVersion = -1;
  // Pending pixel-page request range: when a page request fires for target T
  // with context 150, we mark [T-150, T+150) as "requested".  Any new request
  // whose target falls inside that range is skipped until the response arrives
  // and clears the range.  This prevents the prefetch storm where targets
  // 150, 151, 152... each fire a near-identical 300-row request.
  int _pendingRangeStart = -1;
  int _pendingRangeEnd   = -1;
  int _lastPageToken = 0; // atomic dedup: only merge when Python pushes new data

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
  String? _editPrompt;  // ephemeral prompt shown as italic prefix during editing
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

  // -- Hover tracking --
  int _hoveredRow = -1;
  int _hoveredCol = -1;

  // -- Render code cache: (row,col) → {bg, fg} or null --
  // Invalidated on: scroll (new visible rows), selection change, hover change, data change.
  Map<String, Map<String, String>?> _cellRenderCache = {};
  double _lastRowHeight = 36.0;

  // -- on_key projection (Phase 5 finish) --
  // Pulled from RenderPlaneControl's static registry, keyed by this grid's
  // own Flet control id. The user's spec_code `def on_key(...)` body is
  // wrapped by project_render_funcs as a callable; we eval it via
  // MicroPythonService.execEval on each key press. Replaces the legacy
  // line-split-bare-statement path that used `_onKeyCodeCached` from a
  // page_data blob.
  Map<String, dynamic>? _onKeyProjection;
  Map<String, dynamic>? _renderProjection;
  String _onKeyHostId = '';
  VoidCallback? _onKeyProjectionUnsubscribe;

  // ListController for the main SuperListView — used to invalidate
  // specific row extents when height overrides change.
  final ListController _listController = ListController();



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
    // Subscribe to the on_key projection on the shared RenderPlane,
    // keyed by this grid's own Flet control id. Initial fetch + listener
    // for future projection updates.
    _onKeyHostId = widget.control.id.toString();
    _refreshOnKeyProjection();
    _onKeyProjectionUnsubscribe = RenderPlaneControl.addListener(
        _onKeyHostId, _refreshOnKeyProjection);
    // Process the initial control state — properties were set before
    // the listener was registered, so no notification fired for them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onControlChanged();
    });
  }

  @override
  void dispose() {
    _onKeyProjectionUnsubscribe?.call();
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

  void _refreshOnKeyProjection() {
    if (_onKeyHostId.isEmpty) {
      _onKeyProjection = null;
      _renderProjection = null;
      return;
    }
    _onKeyProjection =
        RenderPlaneControl.getProjection(_onKeyHostId, 'on_key');
    _renderProjection =
        RenderPlaneControl.getProjection(_onKeyHostId, 'render');
    _invalidateRenderCaches();
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

    // Render projection changes are handled by _refreshOnKeyProjection
    // (listener on RenderPlaneControl), not via Flet control properties.

    // -- Pixel-space LOD: two paths --
    // Path 1: data_version changed → clear cache, rebuild source for columns
    // Path 2: page response (rows + pixel_offsets) → merge into cache
    final newDataVersion = widget.control.getInt("data_version", 0) ?? 0;
    final newTotalRows = widget.control.getInt("total_rows", 0) ?? 0;
    final newTotalHeight = widget.control.getDouble("total_height", 0.0) ?? 0.0;
    final newRowHeight = widget.control.getDouble("row_height", 36.0) ?? 36.0;

    if (newDataVersion != _lastDataVersion) {
      // Path 1: data version changed — clear cache, merge fresh data.
      _lastDataVersion = newDataVersion;
      _cache.clear();
      _lastHeightOverridesJson = ''; // force re-apply after clear
      _cache.totalRows = newTotalRows;
      _cache.totalHeight = newTotalHeight;
      _cache.defaultRowHeight = newRowHeight;
      _pendingRangeStart = -1;
      _pendingRangeEnd = -1;
      _lastPageToken = 0; // reset so path 2 merges fresh data

      // Apply sparse row height overrides BEFORE any page merge so
      // extentEstimation returns correct heights for ALL rows from
      // the first frame. Without this, SuperListView's scroll extent
      // diverges from Python's totalHeight and hit testing breaks.
      _applyHeightOverrides();

      // Merge from atomic page_data blob if present.
      _tryMergePageData();

      // Force rebuild
      setState(() {
        _sourceNeedsRebuild = true;
        _invalidateRenderCaches();
      });

      // Request data for current viewport position.
      // The initial page covers rows 0-149 but user may be elsewhere.
      if (newTotalRows > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final currentRow = _yController.hasClients
              ? (_yController.offset / newRowHeight).floor().clamp(0, newTotalRows - 1)
              : 0;
          if (!_cache.has(currentRow)) {
            _requestPixelPage(currentRow);
          }
        });
      }

      // Path 1 complete — skip path 2
      // Fall through to the data-change detection below for column/style updates.
    } else {
      // Always update cache metadata (totalRows may change without version bump)
      _cache.totalRows = newTotalRows;
      _cache.totalHeight = newTotalHeight;
      _cache.defaultRowHeight = newRowHeight;
      _applyHeightOverrides();

      // Path 2: merge page response if pixel offsets are present.
      // Merge from atomic page_data blob.
      if (_tryMergePageData()) {
        setState(() {});
      }
    }

    // Skip full rebuild if data hasn't changed.
    final newRows = widget.control.getString("rows") ?? '';
    final newCols = widget.control.getString("columns") ?? '';
    final newStyles = widget.control.getString("cell_styles") ?? '';
    final newOverrides = widget.control.getString("override_cells") ?? '';
    final newHidden = widget.control.getString("hidden_columns") ?? '';
    final newSummary = widget.control.getString("summary_row") ?? '';
    // Note: row_heights is excluded from the data key because it's page-scoped
    // LOD data (changes on every page_request), not table structure. Including
    // it causes false rebuilds that lose cached heights.
    final dataKey = '$newRows|$newCols|$newTotalRows|$newStyles|$newOverrides|$newHidden|$newSummary|$newRowHeight';
    final oldKey = '$_lastRowsJson|$_lastColsJson|$_lastTotalRows|$_lastStylesJson|$_lastOverridesJson|$_lastHiddenJson|$_lastSummaryJson|$_lastRowHeight';
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
    _lastRowHeight = newRowHeight;

    setState(() {
      _sourceNeedsRebuild = true;
      _lastRequestedOffset = -1; // reset LOD dedup — data changed
      _pendingEdits.clear(); // Python has authoritative data now
      _invalidateRenderCaches(); // data changed → re-evaluate styles
    });
  }

  /// Apply sparse row height overrides from Python. These are pushed
  /// upfront so extentEstimation is correct for ALL rows, even before
  /// their page has been fetched.
  String _lastHeightOverridesJson = '';
  void _applyHeightOverrides() {
    final json = widget.control.getString("row_height_overrides") ?? '';
    if (json == _lastHeightOverridesJson) return; // no change
    _lastHeightOverridesJson = json;
    _cache.clearHeightOverrides();
    if (json.isNotEmpty) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final row = int.tryParse(entry.key);
          final h = (entry.value as num?)?.toDouble();
          if (row != null && h != null) {
            _cache.setHeightOverride(row, h);
          }
        }
      } catch (_) {}
    }
  }

  /// Merge a page response from Python into the pixel-space cache.
  /// Parses rows, pixel offsets, heights, cell styles, and overrides
  /// Try to merge from the atomic page_data blob.
  /// Returns true if new data was merged.
  bool _tryMergePageData() {
    final pageDataJson = widget.control.getString("page_data") ?? '';
    if (pageDataJson.isEmpty) return false;

    try {
      final pd = jsonDecode(pageDataJson) as Map<String, dynamic>;
      final token = pd['token'] as int? ?? 0;
      if (token <= _lastPageToken) return false; // already merged

      final bufferStart = pd['buffer_start'] as int? ?? 0;
      final rows = (pd['rows'] as List)
          .map<List<Object?>>((r) => (r as List).cast<Object?>())
          .toList();
      final allOffsets = (pd['pixel_offsets'] as List)
          .map<double>((e) => (e as num).toDouble())
          .toList();

      // Derive heights from N+1 offsets
      final pixelOffsets = allOffsets.length > rows.length
          ? allOffsets.sublist(0, rows.length) : allOffsets;
      List<double> heights = [];
      for (int i = 0; i < rows.length; i++) {
        if (i + 1 < allOffsets.length) {
          heights.add(allOffsets[i + 1] - allOffsets[i]);
        } else {
          heights.add(_cache.defaultRowHeight);
        }
      }

      // Parse storage indices
      List<int>? storageIndices;
      if (pd['storage_indices'] != null) {
        storageIndices = (pd['storage_indices'] as List)
            .map<int>((e) => (e as num).toInt()).toList();
      }

      // Parse cell styles
      List<List<Map<String, String>?>>? cellStyles;
      if (pd['cell_styles'] != null) {
        cellStyles = (pd['cell_styles'] as List).map<List<Map<String, String>?>>((row) {
          return (row as List).map<Map<String, String>?>((cell) {
            if (cell == null) return null;
            final m = cell as Map;
            return m.map((k, v) => MapEntry(k.toString(), v.toString()));
          }).toList();
        }).toList();
      }

      // Parse override cells
      List<String>? overrideCells;
      if (pd['override_cells'] != null) {
        overrideCells = (pd['override_cells'] as List)
            .map<String>((e) => e.toString()).toList();
      }

      // Apply sparse height overrides for ALL rows (not just this page).
      // This ensures extentEstimation returns correct heights for rows
      // whose page hasn't been fetched yet.
      if (pd['height_overrides'] != null) {
        final ho = pd['height_overrides'] as Map<String, dynamic>;
        for (final entry in ho.entries) {
          final row = int.tryParse(entry.key);
          final h = (entry.value as num?)?.toDouble();
          if (row != null && h != null) {
            _cache.setHeightOverride(row, h);
          }
        }
      }

      // Parse raw rows (unformatted values for render plane)
      List<List<Object?>>? rawRows;
      if (pd['raw_rows'] != null) {
        rawRows = (pd['raw_rows'] as List)
            .map<List<Object?>>((r) => (r as List).cast<Object?>())
            .toList();
      }

      // Merge into cache (mergePage handles override clearing internally)
      _cache.mergePage(
        bufferStart: bufferStart,
        rows: rows,
        pixelOffsets: pixelOffsets,
        heights: heights,
        storageIndices: storageIndices,
        rawRows: rawRows,
        cellStyles: cellStyles,
        overrideCells: overrideCells,
      );

      // Also set raw_rows on control for editing
      if (pd['raw_rows'] != null) {
        widget.control.updateProperties(
            {'raw_rows': jsonEncode(pd['raw_rows'])}, python: false, notify: false);
      }

      // (Phase 5) on_key_code is no longer carried in the page_data blob —
      // it now flows through the canonical RenderPlane projection channel
      // and lives in `_onKeyProjection`, populated by _refreshOnKeyProjection.

      _lastPageToken = token;
      _pendingRangeStart = -1;
      _pendingRangeEnd = -1;
      _tryProcessQueue();

      // Invalidate render caches for merged rows.
      // Clear all rather than per-row removeWhere — the removeWhere with
      // startsWith is O(cacheSize) per row and becomes a bottleneck as
      // the user pages through a large table.
      _cellRenderCache.clear();


      // LRU eviction
      _cache.evictIfNeeded(
        maxPages: 20,
        pageSize: _dynamicPageSize,
      );

      return true;
    } catch (e, st) {
      print('[GRID PAGE_DATA ERROR] $e\n$st');
      return false;
    }
  }

  /// Try to process pending display events from the queue.
  /// Events are processed in order; a PageFault stops processing
  /// and requests the missing page.
  void _tryProcessQueue() {
    bool scrolled = false;
    while (_cache.displayQueue.isNotEmpty) {
      final event = _cache.displayQueue.first;
      final vpHeight = _yController.hasClients
          ? _yController.position.viewportDimension
          : 600.0;
      final result = _cache.walk(event, vpHeight);
      if (result.success) {
        _cache.displayQueue.removeAt(0);
        _scrollToCachedRow(result.row);
        scrolled = true;
      } else {
        // PageFault: request the missing page, stop processing
        _requestPixelPage(result.row);
        break;
      }
    }
    // Rebuild after scroll so selection renders at new position
    if (scrolled) setState(() {});
  }

  /// Scroll to a row using its cached pixel offset. O(1).
  void _scrollToCachedRow(int absRow) {
    if (!_yController.hasClients) return;
    final maxScroll = _yController.position.maxScrollExtent;
    // For the last row, jump to maxScrollExtent (SuperListView's estimate
    // may be less than totalHeight, so cached offset could exceed it).
    if (absRow >= _effectiveRowCount - 1) {
      _yController.jumpTo(maxScroll);
      return;
    }
    final offset = _cache.pixelOffset(absRow);
    if (offset != null) {
      _yController.jumpTo(offset.clamp(0.0, maxScroll));
    }
  }

  /// Request a pixel-space page centered on targetRow from Python.
  /// Context adapts to viewport size via _dynamicPageSize.
  void _requestPixelPage(int targetRow) {
    final int context = (_dynamicPageSize / 2).ceil();
    // Dedup: skip if target falls inside the range already in flight
    if (_cache.has(targetRow)) return; // already cached — no request needed
    if (targetRow >= _pendingRangeStart && targetRow < _pendingRangeEnd) return;

    // Mark the range we're about to request
    _pendingRangeStart = math.max(0, targetRow - context);
    _pendingRangeEnd   = targetRow + context;

    final eventData = jsonEncode({
      "type": "row",
      "target_row": targetRow,
      "context": context,
    });
    widget.control.triggerEventWithoutSubscribers("page_request", eventData);
  }

  /// Build a row from the cache, or return a placeholder if not cached.
  /// This is the entry point for cache-backed rendering. When the row is
  /// in the cache, it delegates to _buildRow (full-featured renderer).
  /// When not cached, returns a SizedBox placeholder and requests the page.
  Widget _buildCachedRow(int absRow, {int colStart = 0, int? colEnd}) {
    if (_cache.has(absRow)) {
      return _buildRow(absRow, colStart: colStart, colEnd: colEnd);
    }
    // Not in cache — show placeholder. Do NOT request pages here —
    // SuperListView probes rows across the entire table for extent
    // estimation, not just visible rows. Page requests come from
    // scroll prefetch and path 1 postFrameCallback only.
    final rh = _cache.rowHeight(absRow);
    return Container(
      height: rh,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: _source.gridLineColor, width: _source.gridLineWidth),
        ),
      ),
      child: rh >= 20 ? Center(
        child: SizedBox(width: 14, height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: _source.gridLineColor,
          ),
        ),
      ) : null,
    );
  }

  /// Get cell text for an absolute row, checking cache first then source.
  String _cachedCellText(int absRow, int col) {
    final cached = _cache.get(absRow);
    if (cached != null && col < cached.data.length) {
      return cached.data[col]?.toString() ?? '';
    }
    return _source.cellText(absRow, col);
  }

  /// Check if a row has an override, checking cache first then source.
  bool _cachedHasOverride(int absRow, String colName) {
    if (_cache.hasOverride(absRow, colName)) return true;
    // Fall back to source for non-LOD mode
    return _source.overrideCells.contains('$absRow:$colName');
  }

  /// Get cell style for an absolute row, checking cache first then source.
  Map<String, String>? _cachedCellStyle(int absRow, int col) {
    final styles = _cache.cellStyles(absRow);
    if (styles != null && col < styles.length) return styles[col];
    return _source.cellStyle(absRow, col);
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
      getCellText: (row, col) => _cachedCellText(row, col),
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
            _editOriginalValue = _cachedCellText(_selectedRow, _selectedCol);
            _editController.text = text;
          });
        }
      },
      scrollToRow: (row) {
        if (_yController.hasClients) {
          // In LOD mode, use cached pixel offset for accurate scroll
          if (_pixelLodActive) {
            final offset = _cache.pixelOffset(row);
            if (offset != null) {
              _yController.jumpTo(offset.clamp(
                  0.0, _yController.position.maxScrollExtent));
              return;
            }
          }
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
              _effectiveRowCount,
              (r) => List.generate(
                  _source.columnCount,
                  (c) => _cachedHasOverride(r, _source.columnName(c)))),
        };
      },
      simulateKey: (key, modifiers) {
        // Simulate key press through the same handler
        // This is a simplified version — full key simulation would
        // create and dispatch actual KeyEvent objects
        if (key == 'Arrow_Down' && _selectedRow < _effectiveRowCount - 1) {
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

  /// Track first visible row for header display + LOD prefetch.
  void _onVerticalScroll() {
    if (!_sourceInitialized) return;
    final rh = _source.rowHeight;
    final newFirst = (_yController.offset / rh).floor();
    if (newFirst != _firstVisibleRow) {
      setState(() {
        _firstVisibleRow = newFirst;
      });
    }

    // Pixel-space LOD prefetch: check if approaching cache boundary.
    // When within 50 rows of a cache edge, request the next page.
    if (_pixelLodActive && _yController.hasClients) {
      final vpHeight = _yController.position.viewportDimension;
      final visibleRows = (vpHeight / rh).ceil();
      final lastVisible = newFirst + visibleRows;

      // Prefetch forward: 50 rows from last cached row ahead
      for (int r = lastVisible; r < math.min(lastVisible + 50, _cache.totalRows); r++) {
        if (!_cache.has(r)) {
          _requestPixelPage(r);
          break;
        }
      }
      // Prefetch backward: 50 rows from first visible row behind
      for (int r = newFirst; r > math.max(newFirst - 50, 0); r--) {
        if (!_cache.has(r)) {
          _requestPixelPage(r);
          break;
        }
      }
    }

    // Legacy LOD: fire page_request at 70% of loaded data (non-pixel-space only)
    if (!_pixelLodActive) {
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

    // Row count for display — use cache totalRows when available
    final effectiveTotalRows = _pixelLodActive
        ? _cache.totalRows : (totalRows > 0 ? totalRows : _source.rowCount);
    final visibleEnd = math.min(
        _firstVisibleRow + _source.visibleRowEstimate, effectiveTotalRows);
    final rowPositionText = effectiveTotalRows > 0
        ? "rows ${_firstVisibleRow + 1}-$visibleEnd of $effectiveTotalRows"
        : "0 rows";

    // -- Error message --
    final errorMessage = widget.control.getString("error_message") ?? "";

    // -- Parse banner level + text --
    String _bannerText = '';
    Color _bannerFg = Colors.transparent;
    IconData? _bannerIcon;
    if (errorMessage.isNotEmpty) {
      _bannerFg = Colors.white;
      _bannerIcon = Icons.error_outline;
      _bannerText = errorMessage;
      if (errorMessage.startsWith('info:')) {
        _bannerText = errorMessage.substring(5);
        _bannerFg = const Color(0xFFB0D4F1);
        _bannerIcon = Icons.info_outline;
      } else if (errorMessage.startsWith('warning:')) {
        _bannerText = errorMessage.substring(8);
        _bannerFg = const Color(0xFFF1D6A0);
        _bannerIcon = Icons.warning_amber_outlined;
      } else if (errorMessage.startsWith('error:')) {
        _bannerText = errorMessage.substring(6);
        _bannerFg = const Color(0xFFFF8A80);
        _bannerIcon = Icons.error_outline;
      }
    }

    // -- Header bar (banner inlined after ctype pill) --
    final headerBar = _buildHeaderBar(
        label, ctype, sortIndicator, filterActive, rowPositionText, context,
        bannerText: _bannerText, bannerFg: _bannerFg, bannerIcon: _bannerIcon);

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
    // Show "No data" only when BOTH source and cache are empty.
    // When pixel-space LOD is active (data_version > 0), the grid body
    // renders placeholders that trigger page requests.
    // Always show grid body — cache will handle missing rows as placeholders
    final hasData = _source.rowCount > 0 || _cache.totalRows > 0 || _lastDataVersion > 0;
    final gridBody = !hasData
        ? const Center(
            child: Text("No data",
                style: TextStyle(color: Colors.grey, fontSize: 14)))
        : _buildGridBody(context, summaryValues: summaryValues);

    // Use LayoutBuilder to handle bounded vs unbounded height.
    // Bounded (Gallery/Fit): Expanded fills available space.
    // Unbounded (Natural mode): grid body determines own height (no Expanded).
    return LayoutControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final unbounded = constraints.maxHeight == double.infinity;

          if (unbounded && _pixelLodActive) {
            // LOD + Natural mode: force bounded height to prevent
            // shrinkWrap from building all items every frame.
            final screenH = MediaQuery.sizeOf(context).height;
            final tableH = (screenH * 0.6).clamp(200.0, screenH - 100.0);
            return SizedBox(
              height: tableH,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  headerBar,
                  Expanded(child: gridBody),
                ],
              ),
            );
          }

          if (unbounded) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                headerBar,
                gridBody,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              headerBar,
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
      bool filterActive, String rowPositionText, BuildContext context,
      {String bannerText = '', Color bannerFg = Colors.transparent,
       IconData? bannerIcon}) {
    final headerBg =
        _color("header_bg_color", context, const Color(0xFF2D2D30));

    // CustomPaint paints background only to _totalColumnsWidth so the
    // chrome bar colour stops at the last column boundary.
    return GestureDetector(
      onSecondaryTapDown: (d) => _showChromeContextMenu(d.globalPosition),
      child: ClipRect(
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
            // H6: Inline banner (info/warning/error)
            if (bannerText.isNotEmpty) ...[
              const SizedBox(width: 8),
              if (bannerIcon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Icon(bannerIcon, size: 12, color: bannerFg),
                ),
              Flexible(
                child: Text(bannerText,
                    style: TextStyle(color: bannerFg, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ],
        ),
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
        final bool cacheActive = _pixelLodActive;
        final hasMore = !cacheActive && totalRows > _source.rowCount;
        final itemCount = cacheActive
            ? _cache.totalRows
            : (_source.rowCount + (hasMore ? 1 : 0));

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
                          SuperListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: itemCount,
                          extentEstimation: (i, _) => i != null
                            ? _cache.fastRowHeight(i)
                            : (_cache.hasHeightOverrides ? 0.0 : _cache.defaultRowHeight),
                            
                            itemBuilder: (context, index) {
                              if (cacheActive) {
                                return _buildCachedRow(index, colEnd: frozenCount);
                              }
                              if (index >= _source.rowCount) {
                                _requestNextPage();
                                return lodSpinner();
                              }
                              return _buildRow(index, colEnd: frozenCount);
                            },
                          )
                        else
                          Expanded(
                            child: SuperListView.builder(
                              controller: _getFrozenController(),
                              itemCount: itemCount,
                          extentEstimation: (i, _) => i != null
                            ? _cache.fastRowHeight(i)
                            : (_cache.hasHeightOverrides ? 0.0 : _cache.defaultRowHeight),
                              
                              itemBuilder: (context, index) {
                                if (cacheActive) {
                                  return _buildCachedRow(index, colEnd: frozenCount);
                                }
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
                              SuperListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: itemCount,
                          extentEstimation: (i, _) => i != null
                            ? _cache.fastRowHeight(i)
                            : (_cache.hasHeightOverrides ? 0.0 : _cache.defaultRowHeight),
                                
                                itemBuilder: (context, index) {
                                  if (cacheActive) {
                                    return _buildCachedRow(index, colStart: frozenCount);
                                  }
                                  if (index >= _source.rowCount) return lodSpinner();
                                  return _buildRow(index, colStart: frozenCount);
                                },
                              )
                            else
                              Expanded(
                                child: SuperListView.builder(
                                  controller: _yController,
                                  listController: _listController,
                                  itemCount: itemCount,
                          extentEstimation: (i, _) => i != null
                            ? _cache.fastRowHeight(i)
                            : (_cache.hasHeightOverrides ? 0.0 : _cache.defaultRowHeight),

                                  itemBuilder: (context, index) {
                                    if (cacheActive) {
                                      return _buildCachedRow(index, colStart: frozenCount);
                                    }
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
                      for (int i = 0; i < frozenRows && i < _effectiveRowCount; i++)
                        _buildRow(i),
                    if (unbounded)
                      SuperListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: scrollableRowCount.clamp(0, itemCount),
                        extentEstimation: (i, _) => i != null
                            ? _cache.fastRowHeight(i)
                            : (_cache.hasHeightOverrides ? 0.0 : _cache.defaultRowHeight),
                        itemBuilder: (context, index) {
                          final actualRow = index + frozenRows;
                          if (cacheActive) {
                            return _buildCachedRow(actualRow);
                          }
                          if (actualRow >= _source.rowCount) {
                            _requestNextPage();
                            return lodSpinner();
                          }
                          return _buildRow(actualRow);
                        },
                      )
                    else
                      Expanded(
                        child: SuperListView.builder(
                          controller: _yController,
                          listController: _listController,
                          itemCount: scrollableRowCount.clamp(0, itemCount),
                          extentEstimation: (i, _) => i != null
                            ? _cache.fastRowHeight(i)
                            : (_cache.hasHeightOverrides ? 0.0 : _cache.defaultRowHeight),
                          itemBuilder: (context, index) {
                            final actualRow = index + frozenRows;
                            if (cacheActive) {
                              return _buildCachedRow(actualRow);
                            }
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
                    value: _checkedRows.length == _effectiveRowCount &&
                        _effectiveRowCount > 0,
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
                    // Left-side resize handle — grabs the PREVIOUS column's
                    // right edge.  This lets the user resize from either side
                    // of the divider (Excel behavior).
                    if (i > colStart)
                      Positioned(
                        left: 0, top: 0, bottom: 0,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            onHorizontalDragStart: (_) {
                              setState(() => _resizingCol = i - 1);
                            },
                            onHorizontalDragUpdate: (d) {
                              setState(() {
                                final current = _getColumnWidth(i - 1);
                                _columnWidthOverrides[i - 1] =
                                    (current + d.delta.dx).clamp(40.0, 4000.0);
                              });
                            },
                            onHorizontalDragEnd: (_) {
                              setState(() => _resizingCol = -1);
                              _fireColumnResize(i - 1);
                            },
                            onDoubleTap: () => _autoSizeColumn(i - 1),
                            behavior: HitTestBehavior.opaque,
                            child: const SizedBox(width: 6),
                          ),
                        ),
                      ),
                    // Right-side resize handle — grabs THIS column's edge
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
    if (_pixelLodActive) return; // pixel LOD uses _requestPixelPage instead
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

    Color? rowBg = _source.rowBackground(rowIndex, isSelected);

    final rh = _getRowHeight(rowIndex);
    return Container(
      key: (isSelected && colStart == 0) ? _selectedRowKey : null,
      height: rh,
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
              height: rh,
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
    // Show optimistic edit value if pending, otherwise cache-aware value
    final pendingKey = '$rowIndex:$colIndex';
    var cellText = _pendingEdits[pendingKey] ??
        _cachedCellText(rowIndex, colIndex);
    final cellStyle = _cachedCellStyle(rowIndex, colIndex);
    Color? fg = cellStyle?['fg'] != null
        ? _parseHexColor(cellStyle!['fg']!)
        : null;
    Color? bg = cellStyle?['bg'] != null
        ? _parseHexColor(cellStyle!['bg']!)
        : null;

    // Merge render plane results with logic plane cell_styles by z-order.
    // For each property, the plane with the higher z wins. This makes
    // code execution order the mental model — last writer wins, naturally.
    final cellRender = _evalCellRender(rowIndex, colIndex);
    double? renderSize;
    FontWeight? renderWeight;
    String? renderFont;
    bool? renderItalic;
    String? renderTooltip;
    if (cellRender != null) {
      // Helper: merge a property by z-order
      int _logicZ(String prop) =>
          int.tryParse(cellStyle?['${prop}_z'] ?? '') ?? -1;
      int _renderZ(String prop) =>
          int.tryParse(cellRender['${prop}_z'] ?? '') ?? -1;

      if (cellRender['bg'] != null && _renderZ('bg') >= _logicZ('bg')) {
        bg = _parseHexColor(cellRender['bg']!) ?? bg;
      }
      if (cellRender['fg'] != null && _renderZ('fg') >= _logicZ('fg')) {
        fg = _parseHexColor(cellRender['fg']!) ?? fg;
      }
      if (cellRender['size'] != null && _renderZ('size') >= _logicZ('size')) {
        renderSize = double.tryParse(cellRender['size']!);
      }
      if (cellRender['weight'] != null && _renderZ('weight') >= _logicZ('weight')) {
        final w = cellRender['weight']!;
        renderWeight = w == 'bold' ? FontWeight.bold
            : w == 'w100' ? FontWeight.w100 : w == 'w200' ? FontWeight.w200
            : w == 'w300' ? FontWeight.w300 : w == 'w400' ? FontWeight.w400
            : w == 'w500' ? FontWeight.w500 : w == 'w600' ? FontWeight.w600
            : w == 'w700' ? FontWeight.w700 : w == 'w800' ? FontWeight.w800
            : w == 'w900' ? FontWeight.w900 : null;
      }
      if (cellRender['font'] != null && _renderZ('font') >= _logicZ('font')) {
        renderFont = cellRender['font'];
      }
      if (cellRender['italic'] != null && _renderZ('italic') >= _logicZ('italic')) {
        renderItalic = cellRender['italic'] == 'true';
      }
      if (cellRender['tooltip'] != null && _renderZ('tooltip') >= _logicZ('tooltip')) {
        renderTooltip = cellRender['tooltip'];
      }
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

    final hasOverride = _cachedHasOverride(rowIndex, colName);
    return Semantics(
      label: 'cell_${rowIndex}_${colIndex}_$cellText',
      child: CustomPaint(
        // Override triangle: foregroundPainter draws ON TOP of the Container
        // at the cell's (0,0) — the outer border corner.  This avoids the
        // negative-offset Positioned that gets clipped by RepaintBoundary.
        foregroundPainter: hasOverride ? _OverrideTrianglePainter() : null,
        child: Container(
          width: _getColumnWidth(colIndex),
          height: _getRowHeight(rowIndex),
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
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      prefix: _editPrompt != null ? Text(
                        '$_editPrompt: ',
                        style: TextStyle(
                          fontSize: _source.cellFontSize,
                          fontFamily: _source.fontFamily,
                          fontStyle: FontStyle.italic,
                          color: Colors.white38,
                        ),
                      ) : null,
                    ),
                    onSubmitted: (_) => _commitEdit(moveDown: true),
                  )
                : _wrapTooltip(renderTooltip, Text(
                    cellText,
                    style: TextStyle(
                      color: textColor == Colors.transparent ? null : textColor,
                      fontSize: renderSize ?? _source.cellFontSize,
                      fontFamily: renderFont ?? _source.fontFamily,
                      fontWeight: renderWeight,
                      fontStyle: renderItalic == true ? FontStyle.italic : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  )),
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
      _selEndRow = _effectiveRowCount - 1;
      _selEndCol = col;
    });
  }

  /// Select all cells.
  void _selectAll() {
    setState(() {
      _selectedRow = 0;
      _selectedCol = 0;
      _selEndRow = _effectiveRowCount - 1;
      _selEndCol = _source.columnCount - 1;
    });
  }

  /// Get selected text as tab-separated values.
  String _getSelectionText() {
    final buf = StringBuffer();
    for (int r = _selMinRow; r <= _selMaxRow; r++) {
      for (int c = _selMinCol; c <= _selMaxCol; c++) {
        if (c > _selMinCol) buf.write('\t');
        buf.write(_cachedCellText(r, c));
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
          'row_index': _storageIndex(r),
          'column_name': colName,
          'old_value': _cachedCellText(r, c),
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
      if (targetRow >= _effectiveRowCount) break;
      for (int c = 0; c < cols.length; c++) {
        final targetCol = _selectedCol + c;
        if (targetCol >= _source.columnCount) break;
        final colName = _source.columnName(targetCol);
        final eventData = jsonEncode({
          'row_index': _storageIndex(targetRow),
          'column_name': colName,
          'old_value': _cachedCellText(targetRow, targetCol),
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
        for (int i = 0; i < _effectiveRowCount; i++) _checkedRows.add(i);
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

  void _startEditing({String? initialText, bool codeMode = false, String? prompt}) {
    if (!_canEdit) return;

    // Get raw value for editing (not display-formatted)
    final rawRowsJson = widget.control.getString("raw_rows");
    String rawValue = _cachedCellText(_selectedRow, _selectedCol);
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
      _editPrompt = prompt;
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
    // Clear any pending optimistic edits for the current cell
    _pendingEdits.remove('$_selectedRow:$_selectedCol');
    setState(() {
      _isEditing = false;
      _isCodeMode = false;
      _editPrompt = null;
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
      _editPrompt = null;
    });

    // Fire on_cell_edit event if value changed
    if (newValue != oldValue) {
      // Optimistic update: try client-side MicroPython formatting first,
      // fall back to raw value. Python round-trip replaces with authoritative.
      final formatted = _clientFormat(_selectedCol, newValue);
      _pendingEdits['$_selectedRow:$_selectedCol'] = formatted ?? newValue;
      final colName = _source.columnName(_selectedCol);
      final eventData = jsonEncode({
        'row_index': _storageIndex(_selectedRow),
        'column_name': colName,
        'old_value': oldValue,
        'new_value': newValue,
      });
      widget.control.triggerEventWithoutSubscribers('cell_edit', eventData);
    }

    // Move selection (collapse range) — scroll: false, cell is adjacent and visible
    if (moveDown && _selectedRow < _effectiveRowCount - 1) {
      _moveTo(_selectedRow + 1, _selectedCol, scroll: false);
    } else if (moveDown && _selectedRow == _effectiveRowCount - 1) {
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

    final row = _hitTestRow(absY);

    // Click-away while editing: commit if user modified the text,
    // cancel if unchanged (safe for initiate_editing(initial_text=...)
    // where the editor opens with synthetic content the user hasn't
    // approved — e.g. Delete key handler).
    if (_isEditing) {
      if (_editController.text != _editValue) {
        _commitEdit();
      } else {
        _cancelEdit();
      }
    }

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
    final row = _hitTestRow(absY);

    if (!_isInSelection(row, col)) {
      _moveTo(row, col, scroll: false);
    }
    _focusNode.requestFocus();

    _showContextMenu(details.globalPosition, row, col);
  }

  /// Show right-click context menu (CM1-CM6, ctype-aware).
  void _showContextMenu(Offset globalPosition, int row, int col) {
    final colName = col < _source.columnCount ? _source.columnName(col) : '';
    final hasOverride = _cachedHasOverride(row, colName);
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
            'row_index': _storageIndex(row),
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

  /// Map a logical key event to a name compatible with the on_key convention.
  ///
  /// Convention (matches flet-einput): structural keys get a stable
  /// PascalCase / Snake_Case name (Enter, Tab, Arrow_Up, ...). Letter keys
  /// always lowercase regardless of Shift / Cmd state — modifiers are
  /// reported separately. On macOS Cmd+letter would otherwise arrive with
  /// `event.character == null` and we'd fall back to the uppercase
  /// `keyLabel == "K"`, breaking user code that checks `key == "k"`.
  String _logicalKeyName(LogicalKeyboardKey key, KeyEvent event) {
    if (key == LogicalKeyboardKey.enter) return 'Enter';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.f2) return 'F2';
    if (key == LogicalKeyboardKey.delete) return 'Delete';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.arrowUp) return 'Arrow_Up';
    if (key == LogicalKeyboardKey.arrowDown) return 'Arrow_Down';
    if (key == LogicalKeyboardKey.arrowLeft) return 'Arrow_Left';
    if (key == LogicalKeyboardKey.arrowRight) return 'Arrow_Right';
    if (key == LogicalKeyboardKey.home) return 'Home';
    if (key == LogicalKeyboardKey.end) return 'End';
    if (key == LogicalKeyboardKey.pageUp) return 'Page_Up';
    if (key == LogicalKeyboardKey.pageDown) return 'Page_Down';
    // Letter keys: always lowercase. keyLabel is "A".."Z" for letters.
    final label = key.keyLabel;
    if (label.length == 1 && label.codeUnitAt(0) >= 0x41 && label.codeUnitAt(0) <= 0x5A) {
      return label.toLowerCase();
    }
    final char = event.character;
    if (char != null && char.isNotEmpty) return char;
    return label;
  }

  /// Build the modifiers list passed to user `on_key` code.
  ///
  /// Reports four literal modifiers (`ctrl`, `meta`, `shift`, `alt`) plus
  /// a derived alias (`cmd`) for the platform-conventional shortcut key —
  /// `meta` on macOS, `ctrl` elsewhere. Identical to flet-einput's helper
  /// so EScalar and ETab on_key handlers see the same modifier vocabulary.
  static List<String> _buildModifiers() {
    final mods = <String>[];
    final hasCtrl = HardwareKeyboard.instance.isControlPressed;
    final hasMeta = HardwareKeyboard.instance.isMetaPressed;
    if (hasCtrl) mods.add('ctrl');
    if (hasMeta) mods.add('meta');
    if (HardwareKeyboard.instance.isShiftPressed) mods.add('shift');
    if (HardwareKeyboard.instance.isAltPressed) mods.add('alt');
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    if ((isMac && hasMeta) || (!isMac && hasCtrl)) mods.add('cmd');
    return mods;
  }

  /// Execute a command chain from on_key evaluation.
  void _executeCommandChain(List<dynamic> commands) {
    for (final cmd in commands) {
      if (cmd is! Map) continue;
      final name = cmd['cmd'] as String? ?? '';
      switch (name) {
        case 'commit':
          if (_isEditing) _commitEdit();
          break;
        case 'move':
          final r = (cmd['row'] as num?)?.toInt() ?? _selectedRow;
          final c = (cmd['col'] as num?)?.toInt() ?? _selectedCol;
          _moveTo(
            r.clamp(0, _effectiveRowCount - 1),
            c.clamp(0, _source.columnCount - 1),
          );
          break;
        case 'initiate_editing':
          final mode = cmd['mode'] as String?;
          final initialText = cmd['initial_text'] as String?;
          final prompt = cmd['prompt'] as String?;
          _startEditing(codeMode: mode == 'code', initialText: initialText, prompt: prompt);
          break;
        case 'cancel_editing':
          if (_isEditing) _cancelEdit();
          break;
        case 'commit_value':
          // Clear cell: fire cell_edit with empty value
          if (_canEdit) {
            final colName = _selectedCol < _source.columnCount
                ? _source.columnName(_selectedCol) : '';
            final storageIdx = _storageIndex(_selectedRow);
            widget.control.triggerEventWithoutSubscribers(
              'cell_edit',
              jsonEncode({
                'row_index': storageIdx,
                'column_name': colName,
                'old_value': _cachedCellText(_selectedRow, _selectedCol),
                'new_value': '',
              }),
            );
          }
          break;
        case 'add_row':
          widget.control.triggerEventWithoutSubscribers(
            'context_action',
            jsonEncode({
              'action': 'add_row',
              'row_index': _selectedRow,
              'column_name': _selectedCol < _source.columnCount
                  ? _source.columnName(_selectedCol) : '',
            }),
          );
          break;
        case 'toggle_checkbox':
          // Toggle checkbox for selected row
          final checkboxCol = widget.control.getBool("show_checkbox_column", false) ?? false;
          if (checkboxCol) {
            widget.control.triggerEventWithoutSubscribers(
              'checkbox_selection',
              jsonEncode({'selected_rows': [_selectedRow]}),
            );
          }
          break;
        case 'beep':
          // No-op — absorbs the key event without action
          break;
        case 'banner':
          final msg = cmd['message'] as String? ?? '';
          final level = cmd['level'] as String? ?? 'info';
          widget.control.updateProperties(
              {'error_message': '$level:$msg'}, python: false, notify: false);
          break;
        case 'select':
          final r = (cmd['row'] as num?)?.toInt() ?? _selectedRow;
          final c = (cmd['col'] as num?)?.toInt() ?? _selectedCol;
          _moveTo(r.clamp(0, _effectiveRowCount - 1),
                  c.clamp(0, _source.columnCount - 1), scroll: false);
          break;
        case 'scroll_to':
          final r = (cmd['row'] as num?)?.toInt() ?? _selectedRow;
          _scrollToCachedRow(r.clamp(0, _effectiveRowCount - 1));
          break;
      }
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_sourceInitialized) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Clear ephemeral banner on any key event
    final curBanner = widget.control.getString("error_message") ?? '';
    if (curBanner.isNotEmpty) {
      widget.control.updateProperties(
          {'error_message': ''}, python: false, notify: false);
      setState(() {});
    }

    // -- on_key hook (Phase 5): canonical render plane projection path --
    //
    // The user's spec_code `def on_key(...)` body is wrapped by
    // project_render_funcs into a callable; we eval it via
    // MicroPythonService.execEval. ctx carries the per-call args. Returning
    // a non-empty list of commands wins (Dart executes via
    // _executeCommandChain); returning None / [] / a non-list falls through
    // to the hardcoded baseline below.
    //
    // Modifier convention (matches EInputText): ctrl/meta/shift/alt are
    // literal modifiers; `cmd` is a derived alias for the platform-
    // conventional shortcut key (meta on macOS, ctrl elsewhere). Users
    // should reach for `"cmd" in modifiers` for cross-platform shortcuts.
    if (_onKeyProjection != null && MicroPythonService.isReady) {
      final proj = _onKeyProjection!;
      final execBody = proj['exec'] as String? ?? '';
      final evalExpr = proj['eval'] as String? ?? '';
      if (evalExpr.isNotEmpty) {
        final keyName = _logicalKeyName(key, event);
        final mods = _buildModifiers();
        final ctx = <String, dynamic>{
          'key': keyName,
          'modifiers': mods,
          'row': _selectedRow,
          'col': _selectedCol,
          'col_name': _selectedCol < _source.columnCount
              ? _source.columnName(_selectedCol) : '',
          'editing': _isEditing,
          'value': _cachedCellText(_selectedRow, _selectedCol),
          'total_rows': _effectiveRowCount,
          'total_cols': _source.columnCount,
        };
        try {
          final result = MicroPythonService.execEval(execBody, evalExpr, ctx);
          if (result != null && result is List && result.isNotEmpty) {
            setState(() {
              _executeCommandChain(result);
            });
            return KeyEventResult.handled;
          }
          // result null / non-list / empty → fall through to baseline
        } catch (e) {
          widget.control.updateProperties(
              {'error_message': '[on_key] ERROR: $e'},
              python: false, notify: false);
          setState(() {});
          // MicroPython error → fall through to baseline
        }
      }
    }

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
      final maxRow = _effectiveRowCount - 1;
      final targetRow = isCtrl ? maxRow
          : (isShift ? _selEndRow + 1 : _selectedRow + 1);
      final row = targetRow.clamp(0, maxRow);
      if (isShift) {
        setState(() => _selEndRow = row);
      } else if (isCtrl) {
        // Ctrl+Down: jump to last row — use display event for cache
        _moveTo(row, _selectedCol, scroll: false);
        if (_pixelLodActive) {
          _cache.enqueue(DisplayEvent(row, DisplayPosition.bottom));
          _tryProcessQueue();
        } else {
          _scrollToEdge(bottom: true);
        }
      } else {
        // Single step: delta scroll only if target not visible
        if (!_isRowVisible(row) && _yController.hasClients) {
          if (_pixelLodActive && _cache.has(row)) {
            _scrollToCachedRow(row);
          } else {
            _yController.jumpTo(
                (_yController.offset + _source.rowHeight)
                    .clamp(0.0, _yController.position.maxScrollExtent));
          }
        }
        _moveTo(row, _selectedCol, scroll: false);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      final maxRow = _effectiveRowCount - 1;
      final targetRow = isCtrl ? 0
          : (isShift ? _selEndRow - 1 : _selectedRow - 1);
      final row = targetRow.clamp(0, maxRow);
      if (isShift) {
        setState(() => _selEndRow = row);
      } else if (isCtrl) {
        // Ctrl+Up: jump to first row — use display event for cache
        _moveTo(row, _selectedCol, scroll: false);
        if (_pixelLodActive) {
          _cache.enqueue(DisplayEvent(row, DisplayPosition.top));
          _tryProcessQueue();
        } else {
          _scrollToEdge(bottom: false);
        }
      } else {
        // Single step: delta scroll only if target not visible
        if (!_isRowVisible(row) && _yController.hasClients) {
          if (_pixelLodActive && _cache.has(row)) {
            _scrollToCachedRow(row);
          } else {
            _yController.jumpTo(
                (_yController.offset - _source.rowHeight)
                    .clamp(0.0, _yController.position.maxScrollExtent));
          }
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
        _ensureColumnVisible(col);
      } else {
        _moveTo(_selectedRow, col);  // scroll: true → _ensureColumnVisible
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final targetCol = isCtrl ? 0
          : (isShift ? _selEndCol - 1 : _selectedCol - 1);
      final col = targetCol.clamp(0, _source.columnCount - 1);
      if (isShift) {
        setState(() => _selEndCol = col);
        _ensureColumnVisible(col);
      } else {
        _moveTo(_selectedRow, col);  // scroll: true → _ensureColumnVisible
      }
      handled = true;

    // -- Home/End --
    } else if (key == LogicalKeyboardKey.home && isCtrl) {
      _moveTo(0, 0, extend: isShift);
      handled = true;
    } else if (key == LogicalKeyboardKey.end && isCtrl) {
      final lastRow = _effectiveRowCount - 1;
      final lastCol = _source.columnCount - 1;
      _moveTo(lastRow, lastCol, extend: isShift);
      if (_pixelLodActive) {
        _cache.enqueue(DisplayEvent(lastRow, DisplayPosition.bottom));
        _tryProcessQueue();
      }
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
      final maxRow = _effectiveRowCount - 1;
      final row = (_selectedRow + visibleRows).clamp(0, maxRow);
      _moveTo(row, _selectedCol, scroll: false);
      if (_pixelLodActive) {
        _cache.enqueue(DisplayEvent(row, DisplayPosition.top));
        _tryProcessQueue();
      } else {
        _scrollToAnchor();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.pageUp) {
      final visibleRows = _yController.hasClients
          ? (_yController.position.viewportDimension / _source.rowHeight).floor()
          : 10;
      final maxRow = _effectiveRowCount - 1;
      final row = (_selectedRow - visibleRows).clamp(0, maxRow);
      _moveTo(row, _selectedCol, scroll: false);
      if (_pixelLodActive) {
        _cache.enqueue(DisplayEvent(row, DisplayPosition.top));
        _tryProcessQueue();
      } else {
        _scrollToAnchor();
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      // Delete/Backspace: start editing with empty text (non-destructive).
      // User must press Enter to confirm clear, or Escape to restore.
      if (_canEdit) {
        _startEditing(initialText: '');
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
    // Only measure cached rows — at 1M rows we can't create 1M TextPainters.
    // Cached rows are the ones the user has actually seen.
    for (final entry in _cache.cachedEntries) {
      final data = entry.value.data;
      final text = col < data.length ? (data[col]?.toString() ?? '') : '';
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
    if (col < 0 || col >= _source.columnCount) return true;
    if (_source.isColumnHidden(col)) return false;
    final colLeft = _scrollableColLeft(col);
    final colRight = colLeft + _getColumnWidth(col);
    final offset = _xController.offset;
    final vw = _xController.position.viewportDimension;
    return colLeft >= offset && colRight <= offset + vw;
  }

  /// Is row `row` fully visible in the vertical viewport?
  bool _isRowVisible(int row) {
    if (!_yController.hasClients) return true;
    final offset = _yController.offset;
    final vh = _yController.position.viewportDimension;
    if (_pixelLodActive) {
      final cached = _cache.get(row);
      if (cached != null) {
        return cached.pixelOffset >= offset &&
            cached.pixelOffset + cached.height <= offset + vh;
      }
    }
    final rowTop = row * _source.rowHeight;
    final rowBottom = rowTop + _source.rowHeight;
    return rowTop >= offset && rowBottom <= offset + vh;
  }

  /// Hit-test: find which row is at absolute pixel position `absY`.
  /// O(1) estimate-and-refine when LOD active, O(1) division otherwise.
  int _hitTestRow(double absY) {
    final maxRow = _effectiveRowCount - 1;
    if (maxRow < 0) return 0;
    if (_pixelLodActive) {
      // With per-index extentEstimation (when height overrides exist),
      // SuperListView's scroll extent matches Python's totalHeight
      // exactly. absY maps directly to cached pixel offsets.
      final avgH = _cache.totalRows > 0
          ? _cache.totalHeight / _cache.totalRows
          : _cache.defaultRowHeight;
      int est = avgH > 0 ? (absY / avgH).floor().clamp(0, maxRow) : 0;
      // Refine using cached pixel offsets
      final lo = math.max(0, est - 50);
      final hi = math.min(maxRow, est + 50);
      for (int r = lo; r <= hi; r++) {
        final cached = _cache.get(r);
        final top = cached?.pixelOffset ?? r * avgH;
        final h = cached?.height ?? avgH;
        if (absY < top + h) return r;
      }
      return est;
    }
    return (absY / _source.rowHeight).floor().clamp(0, maxRow);
  }

  /// Is pixel-space LOD mode active? True when Python has pushed data_version > 0.
  bool get _pixelLodActive => _lastDataVersion > 0 && _cache.totalRows > 0;

  /// Effective row count: cache totalRows when pixel-space LOD active, else source rowCount.
  int get _effectiveRowCount =>
      _pixelLodActive ? _cache.totalRows : _source.rowCount;

  /// Dynamic page size based on viewport. Adapts to screen size and row density.
  int get _dynamicPageSize {
    if (_yController.hasClients) {
      return (_yController.position.viewportDimension /
              _cache.defaultRowHeight * 2)
          .round()
          .clamp(200, 1000);
    }
    return 150;
  }

  /// Map display row index to storage index. Uses cache when LOD active.
  /// When no sort/filter, storage index == display index.
  int _storageIndex(int displayRow) {
    if (_pixelLodActive) {
      return _cache.get(displayRow)?.storageIndex ?? displayRow;
    }
    return displayRow;
  }

  /// Row height: cache-aware. Uses cache height in LOD mode, else source.
  double _getRowHeight(int row) {
    if (_pixelLodActive) return _cache.rowHeight(row);
    return _source.getRowHeight(row);
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
  // Hover tracking
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

          _cellRenderCache.removeWhere((k, _) => k.startsWith('$old:'));
        });
      }
      return;
    }
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    final xOffset = _xController.hasClients ? _xController.offset : 0.0;
    final row = _hitTestRow(yOffset + dataY);

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

          _cellRenderCache.removeWhere((k, _) => k.startsWith('$old:'));
        });
      }
      return;
    }

    if (row != _hoveredRow || col != _hoveredCol) {
      final oldRow = _hoveredRow;
      final colChanged = col != _hoveredCol;
      setState(() {
        _hoveredRow = row;
        _hoveredCol = col;
        if (colChanged && _renderProjection != null) {
          _cellRenderCache.clear();
    
        } else {
          _cellRenderCache.removeWhere(
              (k, _) => k.startsWith('$oldRow:') || k.startsWith('$row:'));
        }
      });
    }
  }

  void _onHoverExit() {
    if (_hoveredRow != -1 || _hoveredCol != -1) {
      final oldHover = _hoveredRow;
      setState(() {
        _hoveredRow = -1;
        _hoveredCol = -1;
        if (_renderProjection != null) {
          _cellRenderCache.clear();
    
        } else {
          _cellRenderCache.removeWhere(
              (k, _) => k.startsWith('$oldHover:'));
        }
      });
    }
  }


  /// Evaluate spec_code def render() for a cell via MicroPython.
  /// Uses the render plane projection + cell bridge.
  /// Returns {bg, fg, weight, ...} dict or null. Cached per-cell.
  Map<String, String>? _evalCellRender(int rowIndex, int colIndex) {
    if (_renderProjection == null || !MicroPythonService.isReady) return null;

    final key = '$rowIndex:$colIndex';
    if (_cellRenderCache.containsKey(key)) {
      return _cellRenderCache[key];
    }

    final proj = _renderProjection!;
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String? ?? '';
    if (evalExpr.isEmpty) {
      _cellRenderCache[key] = null;
      return null;
    }

    final cached = _cache.get(rowIndex);
    // Use raw (unformatted) value so render plane sees numbers, not strings.
    // This matches the logic plane which also passes raw values.
    final cellValue = (cached != null && colIndex < cached.rawData.length)
        ? cached.rawData[colIndex] : null;
    final ctx = <String, dynamic>{
      'value': cellValue,
      'row': cached?.rawData,
      'col_name': colIndex < _source.columnCount
          ? _source.columnName(colIndex) : '',
      'col_index': colIndex,
      'row_index': rowIndex,
      'is_selected': _isInSelection(rowIndex, colIndex),
      'is_hovered': rowIndex == _hoveredRow,
      'is_hovered_cell': rowIndex == _hoveredRow && colIndex == _hoveredCol,
      'hovered_col': _hoveredCol,
      'total_rows': _effectiveRowCount,
      'total_cols': _source.columnCount,
      'viewport_pos': rowIndex - _firstVisibleRow,
      'viewport_count': _yController.hasClients
          ? (_yController.position.viewportDimension / _cache.defaultRowHeight).ceil()
          : 20,
    };
    try {
      // Exec the function def + call together (f-strings with format specs
      // only work in exec mode in MicroPython — eval can't handle them).
      // Then eval cell._to_config() to extract the bridge state.
      final config = MicroPythonService.execEval(
          'cell._reset()\n$execBody\n$evalExpr\n',
          'cell._to_config()', ctx);
      if (config is Map && config.isNotEmpty) {
        final style = <String, String>{};
        // Extract property values + z-levels for cross-plane merge
        for (final prop in ['bg', 'color', 'weight', 'size', 'font', 'italic', 'tooltip']) {
          if (config[prop] != null) {
            final dartKey = prop == 'color' ? 'fg' : prop;
            style[dartKey] = config[prop].toString();
            final z = config['${prop}_z'];
            if (z != null) style['${dartKey}_z'] = z.toString();
          }
        }
        _cellRenderCache[key] = style.isEmpty ? null : style;
        return _cellRenderCache[key];
      }
    } catch (_) {}
    _cellRenderCache[key] = null;
    return null;
  }

  /// Invalidate all render caches (on data change, script change).
  void _invalidateRenderCaches() {
    _cellRenderCache.clear();
  }

  /// Wrap a widget in a Tooltip if text is provided.
  Widget _wrapTooltip(String? tooltip, Widget child) {
    if (tooltip == null || tooltip.isEmpty) return child;
    return Tooltip(message: tooltip, child: child);
  }

  /// Pixel offset of column [col] within the scrollable region.
  /// Skips hidden columns and subtracts frozen columns (which are
  /// outside the _xController scroll area).
  double _scrollableColLeft(int col) {
    final frozenCount =
        widget.control.getInt("frozen_columns_count", 0) ?? 0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    // Checkbox lives outside the scroll area when frozen columns exist,
    // but INSIDE the scroll area when there are no frozen columns.
    double left = (frozenCount == 0 && showCheckbox) ? _checkboxColWidth : 0.0;
    final start = (frozenCount > 0) ? frozenCount : 0;
    for (int i = start; i < col; i++) {
      if (!_source.isColumnHidden(i)) left += _getColumnWidth(i);
    }
    return left;
  }

  void _ensureColumnVisible(int col) {
    if (!_xController.hasClients) return;
    if (col < 0 || col >= _source.columnCount) return;
    if (_source.isColumnHidden(col)) return;
    final colLeft = _scrollableColLeft(col);
    final colRight = colLeft + _getColumnWidth(col);
    final viewportWidth = _xController.position.viewportDimension;
    final offset = _xController.offset;
    final maxScroll = _xController.position.maxScrollExtent;
    if (colLeft < offset) {
      _xController.jumpTo(colLeft.clamp(0.0, maxScroll));
    } else if (colRight > offset + viewportWidth) {
      _xController.jumpTo(
          (colRight - viewportWidth).clamp(0.0, maxScroll));
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

