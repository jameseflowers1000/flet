// EpyxGrid — Custom grid widget replacing Syncfusion DataGrid.
// Phase 1: Core rendering, scrolling, selection, test bridge.
// Architecture: SliverList + Focus + GestureDetector (from prototype).
//
// References:
//   - SUPERTAB_WIDGET.md §3, §4.6, §4.7, §7 Phase 1
//   - Prototype: ~/Dropbox/current/epyc/exp/spreadsheet_table1/

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flet/flet.dart';
import 'package:flet_micropython/flet_micropython.dart' show RenderPlaneControl;
import 'package:flet_micropython/src/micropython_service.dart'
    if (dart.library.io) 'package:flet_micropython/src/micropython_service_native.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart'
    show
        PointerSignalEvent,
        PointerScrollEvent,
        PointerPanZoomUpdateEvent;
import 'dart:io' show File, FileMode;
import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:flutter/services.dart';


import 'epyx_grid_cache.dart';
import 'epyx_grid_source.dart';
import 'epyx_grid_test_api.dart';
import 'epyx_grid_dom_stub.dart'
    if (dart.library.js_interop) 'epyx_grid_dom_web.dart' as epyx_grid_dom;

/// Diagnostic write-through used by the on_key path. Mirrors
/// `_einputDiag` in flet-einput so both ETab and EInput keystroke
/// flows surface in the same /tmp/einput_keys.log file.
/// On web the file API throws; gate with kIsWeb.
void _etabKeyDiag(String msg) {
  final stamp = DateTime.now().toIso8601String();
  if (kIsWeb) {
    print('[etab_key] $stamp $msg');
    return;
  }
  try {
    File('/tmp/einput_keys.log').writeAsStringSync(
      '[$stamp] [etab] $msg\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    print('[etab_key] $stamp $msg');
  }
}


/// The main EpyxGrid widget. Reads Flet control properties and renders
/// a virtualized grid using SliverList.
class EpyxGrid extends StatefulWidget {
  final Control control;

  const EpyxGrid({super.key, required this.control});

  @override
  State<EpyxGrid> createState() => _EpyxGridState();
}

class _EpyxGridState extends State<EpyxGrid>
    with SingleTickerProviderStateMixin {
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

  // -- ETB-19: Cmd/Meta-modifier of the last tap. Captured in
  //    _onTapDown / _onPanStart, emitted in selection_change so the
  //    orchestrator can route plain-click → pick (insert reference)
  //    and Cmd-click → retarget (keep editing a different cell).
  bool _lastSelectMeta = false;

  // -- ETB-19: raw-pointer drag detection used in PICK MODE only.
  //    Flutter's GestureDetector pan recognisers were unreliable
  //    against the row-list's drag (gesture arena races). The Listener
  //    that wraps the build in pick mode bypasses the arena entirely:
  //    onPointerDown captures the start, onPointerMove starts the
  //    drag once we cross a small threshold, onPointerUp emits the
  //    selection_change (single cell if no drag, range otherwise).
  Offset? _pickDownPos;
  bool _pickIsDragging = false;
  static const double _pickDragThreshold = 4.0;
  // Last seen pointer position during pick-mode drag. Wheel events
  // re-hit-test against this so the user can scroll-then-release
  // without having to jiggle the cursor.
  Offset? _pickLastPointerPos;
  // ETB-19 marching-ants: animation driver + parsed picks. Repaint
  // listenable is the merge of the controller + scroll controllers,
  // so the painter ticks every frame AND on scroll.
  late final AnimationController _antsController;
  List<({int row, String col})> _pickedCells = const [];
  String _lastPickedCellsJson = '';

  // -- ETB-09c: global (window) pixel RECT of the cell whose tap/drag
  //    drove the current selection. Sent in selection_change so the
  //    cell-formula popup can sit beside the cell (anchored off the
  //    cell edge, not the tap point — so it never overlaps the cell)
  //    with a caret centred on the cell. Null for keyboard-driven
  //    selection (Python falls back to a fixed popup position).
  Rect? _lastSelectRect;

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
    // ETB-19: marching-ants AnimationController. Runs continuously while
    // _picked_cells is non-empty (started lazily on first paint).
    _antsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
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
    _antsController.dispose();
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
    _etabKeyDiag('refreshOnKeyProjection hostId=$_onKeyHostId '
        'on_key=${_onKeyProjection != null} '
        'render=${_renderProjection != null}');
    _invalidateRenderCaches();
    // The listener that calls us doesn't trigger a rebuild on its own;
    // without a setState the cache clear has no visible effect until the
    // user scrolls/hovers/clicks. Force a rebuild via post-frame so this
    // is safe to call from initState too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _onControlChanged() {
    if (!mounted) return;
    _refreshPickedCells();

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
    // Tab-nav metadata mirrored from the host ETab Property. The whole
    // grid is a single focus stop within the group — once focused, the
    // grid's own arrow-key navigation moves between cells.
    final tabGroup = widget.control.getInt("tab_group");
    final tabOrder = widget.control.getInt("tab_order");
    final tabSkip = widget.control.getBool("tab_skip", false) ?? false;
    final tabName = widget.control.getString("tab_name", "") ?? "";

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
    final pickModeActive =
        widget.control.getBool("pick_mode_active", false) ?? false;
    return EpyxFocusable(
      name: tabName.isEmpty ? "etab:${widget.control.id}" : tabName,
      group: tabGroup,
      order: tabOrder,
      skip: tabSkip,
      isProxy: true,
      proxyToFocusNode: _focusNode,
      drawFocusBorder: true,
      // ETB-19: a tap while pick_mode_active is a reference pick — the
      // wrapper skips its tab-group activate + requestFocus so the
      // editor in the cell-formula popup keeps keyboard focus.
      skipFocusOnTap: pickModeActive,
      child: LayoutControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final unbounded = constraints.maxHeight == double.infinity;

          if (unbounded && _pixelLodActive) {
            // LOD + Natural mode: we MUST bound the height so the virtual list
            // doesn't shrinkWrap-build every row each frame (the whole reason
            // this branch exists — random-million regressed when this bound was
            // miscomputed).
            final screenH = MediaQuery.sizeOf(context).height;
            final ceiling = (screenH * 0.6).clamp(200.0, screenH - 100.0);
            final summaryH =
                summaryValues.isNotEmpty ? _source.rowHeight : 0.0;
            // gridBody = column-header row + data rows + (summary footer).
            final contentH =
                _source.headerRowHeight + _cache.totalHeight + summaryH;
            // Only treat as "small" when the ENTIRE table provably fits under
            // the ceiling with a known height. Everything else (large tables,
            // and the pre-load frame where the height isn't known yet) takes
            // the ORIGINAL, untouched ceiling path below — zero behavior change
            // for random-million.
            final knownSmall = _cache.totalRows > 0 &&
                _cache.totalHeight > 0.0 &&
                contentH <= ceiling;
            if (knownSmall) {
              // Small table: hug its content so the summary footer sits right
              // below the last row instead of being stranded at the bottom of
              // a fixed 60%-screen box.
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  headerBar,
                  SizedBox(height: contentH, child: gridBody),
                ],
              );
            }
            // ORIGINAL behavior (unchanged) for large / not-yet-measured tables.
            return SizedBox(
              height: ceiling,
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

          // Bound the row-list height so the summary row sits directly below
          // the last data row when the viewport is taller than the content,
          // instead of being pushed to the bottom of the viewport. Mirrors the
          // no-frozen-columns path below. Frozen COLUMNS only — this path has
          // no frozen ROWS, so there's no frozen-rows term. Used by the bounded
          // (!unbounded) branches; unbounded panels shrink-wrap as before.
          final summaryH = summaryValues.isEmpty
              ? 0.0
              : _summaryRowHeight(summaryValues);
          final scrollContentH = _cache.totalHeight.clamp(0.0, double.infinity);
          final availForList =
              (constraints.maxHeight - _source.headerRowHeight - summaryH)
                  .clamp(0.0, double.infinity);
          final boundedListH = scrollContentH > 0
              ? math.min(scrollContentH, availForList)
              : availForList;

          // ETB-01 legacy flag.
          final allowLegacyDragSelect =
              widget.control.getBool("allow_drag_select", false) ?? false;
          // ETB-19: pick mode also yields scroll (physics gate) so the
          // Listener can see pointer moves cleanly. But the pan
          // recognisers stay NULL in pick mode — the Listener drives
          // drag detection; wiring pan would double-fire.
          final pickModeActive =
              widget.control.getBool("pick_mode_active", false) ?? false;
          // ETB-19: NeverScrollable kicks in only while a press is
          // in progress (drag-pick). When no press, scroll physics is
          // normal so wheel / two-finger swipe works natively (Excel
          // pattern: click anchor → scroll → shift-click endpoint).
          final pickPressActive = pickModeActive && _pickDownPos != null;
          final allowDragSelect = allowLegacyDragSelect || pickPressActive;
          final wirePan = allowLegacyDragSelect && !pickPressActive;
          return Focus(
            focusNode: _focusNode,
            onKeyEvent: _onKeyEvent,
            child: Listener(
              // ETB-19: raw-pointer drag detection runs in pick mode
              // (no-op otherwise). Listener fires regardless of the
              // gesture arena, so the row-list's scroll recogniser
              // can't claim the drag.
              onPointerDown: _onPickPointerDown,
              onPointerMove: _onPickPointerMove,
              onPointerUp: _onPickPointerUp,
              onPointerCancel: _onPickPointerCancel,
              onPointerSignal: _onPickPointerSignal,
              onPointerPanZoomUpdate: _onPickPanZoomUpdate,
              child: GestureDetector(
              onTapDown: (details) => _onTapDown(details),
              // ETB-19: suppress cell context menu in pick mode — a slow
              // press can be misread as a secondary tap and pop the menu
              // mid-drag.
              onSecondaryTapDown: pickModeActive
                  ? null
                  : (details) => _onSecondaryTapDown(details),
              onPanStart: wirePan ? _onPanStart : null,
              onPanUpdate: wirePan ? _onPanUpdate : null,
              onPanEnd: wirePan ? _onPanEnd : null,
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
                          SizedBox(
                            height: boundedListH,
                            child: SuperListView.builder(
                              controller: _getFrozenController(),
                              // ETB-19: same as the scrollable panel below
                              // — disable the inner scroll while drag-pick
                              // is on so onPanStart wins the arena.
                              physics: allowDragSelect
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
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
                              SizedBox(
                                height: boundedListH,
                                child: SuperListView.builder(
                                  controller: _yController,
                                  listController: _listController,
                                  // ETB-19: while drag-pick is enabled
                                  // (pick mode), the row list MUST NOT
                                  // own vertical drags — otherwise its
                                  // scroll recogniser wins the arena
                                  // before _onPanStart can fire. Scroll
                                  // resumes when the popup closes.
                                  physics: allowDragSelect
                                      ? const NeverScrollableScrollPhysics()
                                      : null,
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
            ),
          );
        }

        // No frozen columns: single horizontal scroll wraps everything
        final frozenRows = widget.control.getInt("frozen_rows_count", 0) ?? 0;
        final scrollableRowCount = itemCount - frozenRows;

        // Bounded height for the scrollable list: when the viewport is taller
        // than (column header + rows + summary), size the list to its content
        // so the summary row sits DIRECTLY below the last data row instead of
        // being pushed to the bottom of the viewport. When content overflows,
        // it fills the remaining space and scrolls (summary stays pinned).
        double _frozenRowsH = 0;
        for (int i = 0; i < frozenRows && i < _effectiveRowCount; i++) {
          _frozenRowsH += _getRowHeight(i);
        }
        final _summaryH =
            summaryValues.isEmpty ? 0.0 : _summaryRowHeight(summaryValues);
        final _scrollContentH =
            (_cache.totalHeight - _frozenRowsH).clamp(0.0, double.infinity);
        final _availForList = (constraints.maxHeight -
                _source.headerRowHeight - _summaryH - _frozenRowsH)
            .clamp(0.0, double.infinity);
        // Hug content when it fits; fill (and scroll) when it overflows or the
        // content height isn't known yet (pre-load frame), so the list is never
        // momentarily empty.
        final boundedListH = _scrollContentH > 0
            ? math.min(_scrollContentH, _availForList)
            : _availForList;

        // ETB-01 legacy flag.
        final allowLegacyDragSelect =
            widget.control.getBool("allow_drag_select", false) ?? false;
        // ETB-19: NeverScrollable kicks in only while a press is in
        // progress (drag-pick). When no press, scroll physics is
        // normal so wheel / two-finger swipe works natively (Excel
        // pattern: click anchor → scroll → shift-click endpoint).
        // Pan recognisers stay NULL in pick mode — Listener drives drag.
        final pickModeActive =
            widget.control.getBool("pick_mode_active", false) ?? false;
        final pickPressActive = pickModeActive && _pickDownPos != null;
        final allowDragSelect = allowLegacyDragSelect || pickPressActive;
        final wirePan = allowLegacyDragSelect && !pickPressActive;
        return MouseRegion(
          onHover: (event) => _onHover(event.localPosition),
          onExit: (_) => _onHoverExit(),
          child: Focus(
            focusNode: _focusNode,
            onKeyEvent: _onKeyEvent,
            child: Listener(
              // ETB-19: raw-pointer drag detection — same as the
              // frozen-columns path above.
              onPointerDown: _onPickPointerDown,
              onPointerMove: _onPickPointerMove,
              onPointerUp: _onPickPointerUp,
              onPointerCancel: _onPickPointerCancel,
              onPointerSignal: _onPickPointerSignal,
              onPointerPanZoomUpdate: _onPickPanZoomUpdate,
              child: GestureDetector(
              onTapDown: (details) => _onTapDown(details),
              // ETB-19: suppress cell context menu in pick mode — a slow
              // press can be misread as a secondary tap and pop the menu
              // mid-drag.
              onSecondaryTapDown: pickModeActive
                  ? null
                  : (details) => _onSecondaryTapDown(details),
              onPanStart: wirePan ? _onPanStart : null,
              onPanUpdate: wirePan ? _onPanUpdate : null,
              onPanEnd: wirePan ? _onPanEnd : null,
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
                      SizedBox(
                        height: boundedListH,
                        child: Stack(
                          children: [
                            SuperListView.builder(
                              controller: _yController,
                              listController: _listController,
                              // ETB-19: scroll yields to drag-pick in pick mode.
                              physics: allowDragSelect
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
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
                            if (_pickedCells.isNotEmpty)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: _buildMarchingAntsOverlay(),
                                ),
                              ),
                          ],
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
        ),
        );
      },
    );
  }

  /// ETB-19 marching-ants overlay — CustomPaint over the SuperListView.
  /// The painter receives a CALLBACK that resolves (row, col_name) to a
  /// viewport-space rect at paint time, NOT a precomputed rect list —
  /// computing rects at build time would freeze them at the old scroll
  /// offset, and `paint()` only re-runs (not the build) when the
  /// repaint Listenable fires for animation ticks / scroll changes.
  Widget _buildMarchingAntsOverlay() {
    return CustomPaint(
      painter: _MarchingAntsPainter(
        picks: _pickedCells,
        animation: _antsController,
        resolveRect: _pickedCellViewportRect,
        extraRepaint: _yController,
      ),
    );
  }

  /// Height the summary/footer row needs (grows to fit the largest
  /// the.cell.size; 1.4× covers ascenders + descenders).
  double _summaryRowHeight(List<String> values,
      {int colStart = 0, int? colEnd}) {
    final endCol = colEnd ?? _source.columnCount;
    double maxSize = _source.cellFontSize;
    for (int i = colStart; i < endCol; i++) {
      if (_source.isColumnHidden(i)) continue;
      final s = _evalSummaryRender(i, values)?['size']; // cached per cell
      final d = s == null ? null : double.tryParse(s);
      if (d != null && d > maxSize) maxSize = d;
    }
    return math.max(_source.rowHeight, maxSize * 1.4 + 2 * _source.cellPaddingV);
  }

  /// Summary row — fixed footer with aggregated values.
  Widget _buildSummaryRow(List<String> values,
      {int colStart = 0, int? colEnd}) {
    final endCol = colEnd ?? _source.columnCount;
    final headerBg =
        _color("header_bg_color", context, const Color(0xFF2D2D30));
    final rowHeight =
        _summaryRowHeight(values, colStart: colStart, colEnd: colEnd);

    return Container(
      height: rowHeight,
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
              _buildSummaryCell(i, values, rowHeight),
        ],
      ),
    );
  }

  /// One footer cell, styled by the same render code the data cells use, run
  /// with is_summary=true (so `if the.cell.is_summary: the.cell.size = 28`
  /// applies here).
  Widget _buildSummaryCell(int i, List<String> values, double rowHeight) {
    final sr = _evalSummaryRender(i, values);
    Color fg = Colors.white;
    Color? cellBg;
    double size = _source.cellFontSize;
    FontWeight weight = FontWeight.w600;
    String? font = _source.fontFamily;
    bool italic = false;
    String text = i < values.length ? values[i] : '';
    if (sr != null) {
      if (sr['fg'] != null) fg = _parseHexColor(sr['fg']!) ?? fg;
      if (sr['bg'] != null) cellBg = _parseHexColor(sr['bg']!);
      if (sr['size'] != null) size = double.tryParse(sr['size']!) ?? size;
      if (sr['font'] != null) font = sr['font'];
      if (sr['italic'] != null) italic = sr['italic'] == 'true';
      if (sr['display'] != null) text = sr['display']!;
      final w = sr['weight'];
      if (w != null) {
        weight = w == 'bold' ? FontWeight.bold
            : w == 'w100' ? FontWeight.w100 : w == 'w200' ? FontWeight.w200
            : w == 'w300' ? FontWeight.w300 : w == 'w400' ? FontWeight.w400
            : w == 'w500' ? FontWeight.w500 : w == 'w600' ? FontWeight.w600
            : w == 'w700' ? FontWeight.w700 : w == 'w800' ? FontWeight.w800
            : w == 'w900' ? FontWeight.w900 : weight;
      }
    }
    // Scale-to-fit with a floor, never blank. Keep the requested size where it
    // fits (a wide Item/total column at size 70 stays 70). Where the value is
    // too wide, shrink the font to fit — but only down to kMinSummaryFont;
    // past that, scaling to a sub-pixel speck is pointless, so hold at the
    // floor and let the ellipsis clip ("The value is 1…") instead.
    //
    // FittedBox does the actual fitting (it measures real layout, so it fits
    // exactly — a TextPainter estimate misses font-weight/text-scaler and
    // leaves the ellipsis biting). A cheap TextPainter estimate only DECIDES
    // which branch: scale (worth it) vs. floor+ellipsis (too small).
    const double kMinSummaryFont = 5.0;
    final textStyle = TextStyle(
      color: fg,
      fontSize: size,
      fontFamily: font,
      fontWeight: weight,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    );
    final align = _source.isNumericColumn(i)
        ? Alignment.centerRight
        : Alignment.centerLeft;
    double estSize = size;
    final availW = _getColumnWidth(i) - 2 * _source.cellPaddingH;
    if (text.isNotEmpty && availW > 0) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > availW) estSize = size * (availW / tp.width);
    }
    final bool scaleToFit = estSize >= kMinSummaryFont;
    return Container(
      width: _getColumnWidth(i),
      height: rowHeight,
      padding: EdgeInsets.symmetric(
        horizontal: _source.cellPaddingH,
        vertical: _source.cellPaddingV,
      ),
      decoration: BoxDecoration(
        color: cellBg,
        border: Border(
          right: BorderSide(
              color: _source.gridLineColor, width: _source.gridLineWidth),
        ),
      ),
      // FittedBox needs tight constraints, so it owns the alignment; the
      // floor branch is a plain Text and leans on Container.alignment.
      alignment: scaleToFit ? null : align,
      child: scaleToFit
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: align,
              child: Text(text,
                  maxLines: 1, softWrap: false, style: textStyle),
            )
          : Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: textStyle.copyWith(fontSize: kMinSummaryFont),
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
    String? renderIcon;
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
      if (cellRender['icon'] != null && _renderZ('icon') >= _logicZ('icon')) {
        renderIcon = cellRender['icon'];
      }
      // Render plane's `display` (from cell.format / cell.display) overrides
      // the raw cellText. Pending edits and explicit display overrides
      // already applied above still win because cellText was set first.
      if (cellRender['display'] != null
          && _pendingEdits[pendingKey] == null) {
        cellText = cellRender['display']!;
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
                    // Route Enter through the on_key projection first so user α
                    // code's `if the.key == the.keys.enter:` handlers fire even
                    // when Enter is pressed inside the inner TextField (i.e.
                    // edit mode entered via type-to-replace, where the TextField
                    // gets focus directly and the grid's outer onKeyEvent never
                    // sees the Enter). Falls back to the baseline commit-and-
                    // move-down on no projection / empty result.
                    onSubmitted: (_) {
                      if (_tryRunOnKeyProjection('Enter')) return;
                      _commitEdit(moveDown: true);
                    },
                  )
                : _wrapTooltip(renderTooltip, _wrapIcon(renderIcon, Text(
                    cellText,
                    style: TextStyle(
                      color: textColor == Colors.transparent ? null : textColor,
                      fontSize: renderSize ?? _source.cellFontSize,
                      fontFamily: renderFont ?? _source.fontFamily,
                      fontWeight: renderWeight,
                      fontStyle: renderItalic == true ? FontStyle.italic : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ), textColor, renderSize ?? _source.cellFontSize)),
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
  void _moveTo(int row, int col, {bool extend = false, bool scroll = true,
      bool fireEvent = true}) {
    final prevRow = _selectedRow;
    final prevCol = _selectedCol;
    final prevEndRow = _selEndRow;
    final prevEndCol = _selEndCol;
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
    // Mirror selection to the DOM for headless tests (web only).
    epyx_grid_dom.publishGridSelection(
        widget.control.id.toString(), row, col);
    // Fire selection_change whenever (anchor or end) actually changed.
    // ETB-06 Gap 1: previously the !extend guard suppressed events for
    // shift-click and shift-arrow paths.  Now both paths fire — but only
    // when the (row, col) under their respective slot actually moved, so
    // we don't spam events on shift-arrow against the bound.
    if (fireEvent) {
      if (extend) {
        if (row != prevEndRow || col != prevEndCol) {
          _fireSelectionChange();
        }
      } else {
        if (row != prevRow || col != prevCol) {
          _fireSelectionChange();
        }
      }
    }
  }

  void _fireSelectionChange() {
    try {
      final colName = _selectedCol >= 0 && _selectedCol < _source.columnCount
          ? _source.columnName(_selectedCol) : '';
      final payload = <String, dynamic>{
        'row': _selectedRow,
        'col': _selectedCol,
        'column_name': colName,
        'end_row': _selEndRow,
        'end_col': _selEndCol,
      };
      // ETB-09c: send the selected cell's global pixel rect so the
      // cell-formula popup sits BESIDE the cell (anchored off its edge,
      // never over it) with a caret centred on the cell. Set in
      // _onTapDown / _onPanStart; null for keyboard-driven selection,
      // where Python falls back to a fixed popup position.
      final r = _lastSelectRect;
      if (r != null) {
        payload['cell_left'] = r.left;
        payload['cell_top'] = r.top;
        payload['cell_right'] = r.right;
        payload['cell_bottom'] = r.bottom;
      }
      // ETB-19: meta=true ⇒ Cmd/Ctrl was held → orchestrator interprets
      // as RETARGET (keep editing a different cell). False ⇒ plain
      // click → PICK (insert reference at editor cursor).
      payload['meta'] = _lastSelectMeta;
      widget.control.triggerEventWithoutSubscribers(
          'selection_change', jsonEncode(payload));
    } catch (_) {
      // Backend may be null in tests
    }
  }

  /// Select entire row.
  void _selectRow(int row) {
    final lastCol = _source.columnCount - 1;
    final changed = _selectedRow != row || _selectedCol != 0 ||
                    _selEndRow != row || _selEndCol != lastCol;
    setState(() {
      _selectedRow = row;
      _selectedCol = 0;
      _selEndRow = row;
      _selEndCol = lastCol;
    });
    if (changed) _fireSelectionChange();
  }

  /// Select entire column.
  void _selectColumn(int col) {
    final lastRow = _effectiveRowCount - 1;
    final changed = _selectedRow != 0 || _selectedCol != col ||
                    _selEndRow != lastRow || _selEndCol != col;
    setState(() {
      _selectedRow = 0;
      _selectedCol = col;
      _selEndRow = lastRow;
      _selEndCol = col;
    });
    if (changed) _fireSelectionChange();
  }

  /// Select all cells.
  void _selectAll() {
    final lastRow = _effectiveRowCount - 1;
    final lastCol = _source.columnCount - 1;
    final changed = _selectedRow != 0 || _selectedCol != 0 ||
                    _selEndRow != lastRow || _selEndCol != lastCol;
    setState(() {
      _selectedRow = 0;
      _selectedCol = 0;
      _selEndRow = lastRow;
      _selEndCol = lastCol;
    });
    // ETB-06 Gap 3: Cmd+A / Ctrl+A must fire selection_change.
    if (changed) _fireSelectionChange();
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

  void _startEditing({String? initialText, bool codeMode = false,
      String? prompt, String? cursor}) {
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
      // Selection model:
      //   cursor == 'end'           → cursor at end, no selection
      //                                (F2 convention: extend existing text)
      //   cursor == 'start'         → cursor at position 0
      //   cursor == 'all' / null    → select all (default — typing replaces;
      //                                spreadsheet convention for type-to-edit
      //                                via Enter / printable key)
      // initial_text is treated as already-replaced content, so cursor
      // lands at end when initial_text was supplied (caller deliberately
      // injected a value).
      if (initialText != null) {
        _editController.selection = TextSelection.collapsed(
            offset: _editController.text.length);
      } else if (cursor == 'end') {
        _editController.selection = TextSelection.collapsed(
            offset: _editController.text.length);
      } else if (cursor == 'start') {
        _editController.selection = const TextSelection.collapsed(offset: 0);
      } else {
        // Default: select all (cursor == 'all' or unspecified).
        _editController.selection = TextSelection(
            baseOffset: 0, extentOffset: _editController.text.length);
      }
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

    // ETB-09c: keyboard nav has no tap rect — clear it so the popup
    // falls back to its fixed position rather than anchoring at the
    // previously-tapped cell.
    _lastSelectRect = null;
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

  /// Hit-test a local pointer position to a (row, col) cell.
  ///
  /// Returns null if the position falls in a non-data area (header band,
  /// checkbox column). Mirrors the math in _onTapDown / _onSecondaryTapDown
  /// and is used by both tap and drag-select handlers. Frozen-column
  /// boundary is honored: positions in the frozen panel use no x-scroll
  /// offset; positions past the frozen panel apply the horizontal scroll.
  ///
  /// Out-of-data positions are clamped to data bounds (per ETB-01: drags
  /// outside data bounds clamp to data bounds, no error).
  ({int row, int col})? _hitTestCell(Offset localPosition) {
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    final headerH = _source.headerRowHeight;
    final dataY = localPosition.dy - headerH;
    if (dataY < 0) return null; // header band

    final frozenCount = widget.control.getInt("frozen_columns_count", 0) ?? 0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    final cbOffset = showCheckbox ? _checkboxColWidth : 0.0;
    var localX = localPosition.dx;
    if (showCheckbox && localX < cbOffset) return null;
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

    final absY = yOffset + dataY;

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
    return (row: row, col: col);
  }

  /// ETB-09c: the GLOBAL (window) rect of cell (row, col), derived from
  /// the tap. We mirror _hitTestCell's abs-space math to find the tap's
  /// offset INTO the cell, then express the cell rect in global coords
  /// relative to the tap (global = local + gridOrigin; the in-cell
  /// offset is the same in local and global space). Works with frozen
  /// columns / checkbox / scroll because absX already accounts for them.
  Rect _cellGlobalRect(Offset local, Offset global, int row, int col) {
    final headerH = _source.headerRowHeight;
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    final cbOffset = showCheckbox ? _checkboxColWidth : 0.0;
    final frozenCount = widget.control.getInt("frozen_columns_count", 0) ?? 0;
    var localX = local.dx - cbOffset;
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
    double cumX = 0;
    for (int i = 0; i < col && i < _source.columnCount; i++) {
      cumX += _getColumnWidth(i);
    }
    final w = _getColumnWidth(col);
    final inCellX = absX - cumX;            // tap offset into the cell (x)
    final cellLeft = global.dx - inCellX;
    final absY = yOffset + (local.dy - headerH);
    final rowTop = row * _source.rowHeight;
    final inCellY = absY - rowTop;          // tap offset into the cell (y)
    final cellTop = global.dy - inCellY;
    return Rect.fromLTWH(cellLeft, cellTop, w, _source.rowHeight);
  }

  void _onTapDown(TapDownDetails details) {
    final hit = _hitTestCell(details.localPosition);
    if (hit == null) return;
    final row = hit.row;
    final col = hit.col;
    // ETB-09c: remember the cell's global rect so selection_change can
    // place the cell-formula popup beside the cell (not over it).
    _lastSelectRect = _cellGlobalRect(
        details.localPosition, details.globalPosition, row, col);
    // ETB-19: record Cmd/Meta (and Ctrl on non-mac) so the orchestrator
    // can route Cmd-click → retarget vs plain click → reference pick.
    _lastSelectMeta = HardwareKeyboard.instance.isMetaPressed
        || HardwareKeyboard.instance.isControlPressed;

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
    // ETB-19: in pick mode, the press might turn into a drag-pick —
    // defer the selection_change to _onTap (only fires when no drag
    // occurred) / _onPanEnd (drag did). Otherwise the user gets BOTH
    // a single-cell pick (from tap_down) AND a range pick (from
    // pan_end) — the editor gets two inserts per drag.
    final pickActive =
        widget.control.getBool("pick_mode_active", false) ?? false;
    _moveTo(row, col,
        extend: HardwareKeyboard.instance.isShiftPressed,
        scroll: false,
        fireEvent: !pickActive);
    // ETB-19: while pick_mode_active, the editor in the cell-formula
    // popup holds focus and we MUST NOT steal it on a tap.
    if (!pickActive) {
      _focusNode.requestFocus();
    }
  }

  // ── ETB-19: raw-pointer drag detection (Listener handlers) ─────────
  //
  // We tap into `Listener` events, which fire BEFORE Flutter's gesture
  // arena and don't compete with scroll views, so we get reliable
  // pointer down/move/up tracking regardless of what GestureDetectors
  // sit underneath. Only active while pick_mode_active is true; outside
  // pick mode these are no-ops and the existing GestureDetector
  // (onTapDown / onPan*) handles selection as before.

  void _onPickPointerDown(PointerDownEvent event) {
    final pickActive =
        widget.control.getBool("pick_mode_active", false) ?? false;
    if (!pickActive) return;
    // setState here so the build path can flip scroll physics to
    // NeverScrollable while a drag is in progress, then back to natural
    // physics on release. Lets wheel / trackpad scroll work natively
    // between clicks (anchor → scroll → shift-click pattern) and via
    // the Listener-driven path during a drag.
    setState(() {
      _pickDownPos = event.localPosition;
      // Seed last-known pos here too: press-and-immediately-trackpad
      // (no PointerMove yet) leaves _applyPickScroll a valid cursor pos.
      _pickLastPointerPos = event.localPosition;
      _pickIsDragging = false;
    });
  }

  void _onPickPointerMove(PointerMoveEvent event) {
    if (_pickDownPos == null) return;
    final dist = (event.localPosition - _pickDownPos!).distance;
    if (!_pickIsDragging) {
      if (dist < _pickDragThreshold) return;
      _pickIsDragging = true;
    }
    _pickLastPointerPos = event.localPosition;
    // Update the selection end-cell as the pointer moves.
    final hit = _hitTestCell(event.localPosition);
    if (hit == null) return;
    if (hit.row == _selEndRow && hit.col == _selEndCol) return;
    setState(() {
      _selEndRow = hit.row;
      _selEndCol = hit.col;
    });
  }

  void _onPickPointerUp(PointerUpEvent event) {
    if (_pickDownPos == null) return;
    _pickDownPos = null;
    _pickIsDragging = false;
    // Fire selection_change. Single cell when no drag (anchor==end);
    // range when drag occurred (anchor!=end). Orchestrator routes
    // based on tl != br in prop.selection.range.
    _fireSelectionChange();
    // ETB-19: collapse the range highlight to the anchor — no
    // lingering blue tint across rows — but KEEP the anchor itself so
    // a subsequent shift+click has something to extend from
    // (click anchor → scroll → shift+click endpoint). Also flips
    // physics back to natural in the same frame.
    setState(() {
      _selEndRow = _selectedRow;
      _selEndCol = _selectedCol;
    });
  }

  void _onPickPointerCancel(PointerCancelEvent event) {
    setState(() {
      _pickDownPos = null;
      _pickIsDragging = false;
      _pickLastPointerPos = null;
    });
  }

  // ETB-19: in pick mode, the SuperListView uses NeverScrollableScrollPhysics
  // so the gesture arena doesn't claim the drag for scrolling. That also
  // blocks wheel / two-finger swipe input though — re-implement both at
  // the Listener level: drive `_yController` manually and re-hit-test
  // under the stationary cursor so the selection extends into the freshly-
  // revealed rows without requiring the user to jiggle the mouse.
  //
  // Two signal types matter on macOS:
  //   * Mouse wheel → PointerSignalEvent (PointerScrollEvent subtype),
  //     handled by onPointerSignal. scrollDelta is ADDED to offset.
  //   * Trackpad two-finger swipe → PointerPanZoomUpdateEvent, handled
  //     by onPointerPanZoomUpdate. panDelta is SUBTRACTED (Flutter
  //     convention — pan direction is opposite of scroll direction).
  void _onPickPointerSignal(PointerSignalEvent event) {
    // Only intercept while a drag-pick is in progress. Outside of that,
    // physics is normal and the SuperListView handles wheel natively —
    // letting BOTH us and it handle it would double-scroll.
    if (_pickDownPos == null) return;
    if (event is! PointerScrollEvent) return;
    _applyPickScroll(event.scrollDelta.dy);
  }

  void _onPickPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_pickDownPos == null) return;
    // Negate: a downward two-finger swipe (panDelta.dy > 0) should
    // reveal earlier content (scroll offset decreases) — macOS natural-
    // scrolling. Flutter's own Scrollable does the same.
    _applyPickScroll(-event.panDelta.dy);
  }

  void _applyPickScroll(double dyDelta) {
    if (!_yController.hasClients || dyDelta == 0) return;
    final pos = _yController.position;
    // Use pointerScroll (Flutter's own Scrollable goes through this) so
    // the SuperListView's internal state — listController, extent
    // estimates, viewport — sees the offset change the way it expects.
    final before = pos.pixels;
    pos.pointerScroll(dyDelta);
    if (pos.pixels == before) return;
    // Extend selection to the row now under the stationary cursor. Only
    // if a drag is in progress (anchor was set).
    if (_pickDownPos == null) return;
    final p = _pickLastPointerPos ?? _pickDownPos!;
    // Direct math instead of _hitTestCell — the cell at p's screen
    // position after scroll might not be in the LOD cache yet, and
    // _hitTestRow's cached-offset path would return a stale row.
    // Headers + checkbox + frozen columns work the same regardless of
    // scroll, so we can compute the absolute row coordinate purely
    // from the new scroll offset.
    final dataY = p.dy - _source.headerRowHeight;
    if (dataY < 0) return;
    final absY = pos.pixels + dataY;
    final rowH = _source.rowHeight > 0 ? _source.rowHeight : 26.0;
    final maxRow = _effectiveRowCount - 1;
    if (maxRow < 0) return;
    final newRow = (absY / rowH).floor().clamp(0, maxRow);
    if (newRow == _selEndRow) return;
    setState(() {
      _selEndRow = newRow;
    });
  }

  // ── ETB-19 marching ants ─────────────────────────────────────────
  //
  // Parses the SuperTab's `picked_cells` JSON ([[row, col_name], …])
  // pushed by the orchestrator after each pick. Starts the animation
  // controller when there's anything to paint and stops it once the
  // set is empty (no point burning frames). Called from
  // _onControlChanged so it stays in sync with Python pushes.
  void _refreshPickedCells() {
    final raw = widget.control.getString("picked_cells") ?? '';
    if (raw == _lastPickedCellsJson) return;
    _lastPickedCellsJson = raw;
    List<({int row, String col})> picks = const [];
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List;
        picks = [
          for (final p in decoded)
            if (p is List && p.length == 2)
              (row: (p[0] as num).toInt(), col: p[1].toString()),
        ];
      } catch (_) {
        picks = const [];
      }
    }
    _pickedCells = picks;
    if (picks.isEmpty) {
      _antsController.stop();
      _antsController.value = 0;
    } else if (!_antsController.isAnimating) {
      _antsController.repeat();
    }
    if (mounted) setState(() {});
  }

  // Resolve a picked cell to its rect in the SuperListView's *viewport*
  // coordinates (i.e. with vertical scroll already subtracted) so the
  // CustomPaint sitting on top of the SuperListView can draw at that rect
  // directly. Horizontal scroll is NOT subtracted because the painter
  // lives inside the horizontal SingleChildScrollView.
  ///
  /// Returns null if the column is unknown OR if the cell is fully
  /// outside the visible vertical viewport (cheap cull).
  Rect? _pickedCellViewportRect(int row, String colName) {
    final colIdx = _source.columnNames.indexOf(colName);
    if (colIdx < 0) return null;
    final rowH = _cache.rowHeight(row);
    final yOffset = _yController.hasClients ? _yController.offset : 0.0;
    final vpH = _yController.hasClients
        ? _yController.position.viewportDimension
        : 0.0;
    final top = row * _source.rowHeight - yOffset;
    if (vpH > 0 && (top + rowH < 0 || top > vpH)) return null;
    // Column horizontal offset within the row body. Match
    // _cellGlobalRect's accounting: checkbox + frozen cols + remaining.
    final showCheckbox =
        widget.control.getBool("show_checkbox_column", false) ?? false;
    final cbOffset = showCheckbox ? _checkboxColWidth : 0.0;
    double cumX = cbOffset;
    for (int i = 0; i < colIdx && i < _source.columnCount; i++) {
      cumX += _getColumnWidth(i);
    }
    final w = _getColumnWidth(colIdx);
    return Rect.fromLTWH(cumX, top, w, rowH);
  }

  // ────────────────────────────────────────────────────────────────
  // Drag-select (ETB-01) — gated by allow_drag_select feature flag.
  // ETB-02: pure view-state mutation. No cell values written, no
  // mark_node_changed, no recalc. _fireSelectionChange() emits one
  // event per drag (on pan-end), not per pan-update.
  // ────────────────────────────────────────────────────────────────

  // Track whether a drag is in progress (to suppress redundant work).
  bool _isDragSelecting = false;

  void _onPanStart(DragStartDetails details) {
    final hit = _hitTestCell(details.localPosition);
    if (hit == null) return;
    _isDragSelecting = true;
    _lastSelectRect = _cellGlobalRect(           // ETB-09c anchor
        details.localPosition, details.globalPosition, hit.row, hit.col);
    // Commit/cancel any in-flight edit before starting a drag selection.
    if (_isEditing) {
      if (_editController.text != _editValue) {
        _commitEdit();
      } else {
        _cancelEdit();
      }
    }
    setState(() {
      _selectedRow = hit.row;
      _selectedCol = hit.col;
      _selEndRow = hit.row;
      _selEndCol = hit.col;
    });
    _focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isDragSelecting) return;
    final hit = _hitTestCell(details.localPosition);
    if (hit == null) return;
    if (hit.row == _selEndRow && hit.col == _selEndCol) return;
    setState(() {
      _selEndRow = hit.row;
      _selEndCol = hit.col;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_isDragSelecting) return;
    _isDragSelecting = false;
    // One selection_change event per drag, on pan-end (not per update).
    _fireSelectionChange();
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

  /// Try to run the user's on_key projection for a given keyName and
  /// execute the resulting command list. Returns true if commands ran
  /// (i.e., projection took ownership of this key event), false if the
  /// caller should fall back to baseline behavior.
  ///
  /// Shared between the grid's outer Focus.onKeyEvent (real KeyEvent
  /// path) and the inner TextField's onSubmitted (Enter inside an
  /// active edit, where the grid never sees the raw KeyEvent because
  /// the TextField captures it). Without this shared path, type-to-
  /// replace + Enter bypassed the projection on platforms where
  /// onSubmitted intercepts (notably macOS desktop).
  bool _tryRunOnKeyProjection(String keyName) {
    if (_onKeyProjection == null || !MicroPythonService.isReady) {
      return false;
    }
    final proj = _onKeyProjection!;
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String? ?? '';
    if (evalExpr.isEmpty) return false;
    final mods = _buildModifiers();
    final ctx = <String, dynamic>{
      'key': keyName,
      'modifiers': mods,
      'row': _selectedRow,
      'col': _selectedCol,
      'row_index': _selectedRow,
      'col_index': _selectedCol,
      'col_name': _selectedCol < _source.columnCount
          ? _source.columnName(_selectedCol) : '',
      'editing': _isEditing,
      'is_editing': _isEditing,
      'value': _isEditing
          ? _editController.text
          : _cachedCellText(_selectedRow, _selectedCol),
      'total_rows': _effectiveRowCount,
      'total_cols': _source.columnCount,
    };
    try {
      final result = MicroPythonService.execEval(execBody, evalExpr, ctx);
      _etabKeyDiag('tryRunOnKeyProjection result type=${result.runtimeType} '
          'value=${result.toString().substring(0, result.toString().length.clamp(0, 200))} '
          'keyName=$keyName editing=$_isEditing');
      if (result != null && result is List && result.isNotEmpty) {
        setState(() { _executeCommandChain(result); });
        return true;
      }
    } catch (e) {
      _etabKeyDiag('tryRunOnKeyProjection EXCEPTION: $e');
      widget.control.updateProperties(
          {'error_message': '[on_key] ERROR: $e'},
          python: false, notify: false);
      setState(() {});
    }
    return false;
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
          // Two forms: explicit (row=, col=) or relative (direction=
          // 'up'/'down'/'left'/'right' with optional `steps`).
          int targetR = (cmd['row'] as num?)?.toInt() ?? _selectedRow;
          int targetC = (cmd['col'] as num?)?.toInt() ?? _selectedCol;
          final direction = cmd['direction'] as String?;
          final dr = (cmd['delta_row'] as num?)?.toInt();
          final dc = (cmd['delta_col'] as num?)?.toInt();
          final steps = (cmd['steps'] as num?)?.toInt() ?? 1;
          if (direction != null) {
            switch (direction) {
              case 'up':    targetR = _selectedRow - steps; break;
              case 'down':  targetR = _selectedRow + steps; break;
              case 'left':  targetC = _selectedCol - steps; break;
              case 'right': targetC = _selectedCol + steps; break;
            }
          }
          if (dr != null) targetR = _selectedRow + dr;
          if (dc != null) targetC = _selectedCol + dc;
          _moveTo(
            targetR.clamp(0, _effectiveRowCount - 1),
            targetC.clamp(0, _source.columnCount - 1),
          );
          break;
        case 'initiate_editing':
          final mode = cmd['mode'] as String?;
          final initialText = cmd['initial_text'] as String?;
          final prompt = cmd['prompt'] as String?;
          final cursor = cmd['cursor'] as String?;
          _startEditing(codeMode: mode == 'code', initialText: initialText,
              prompt: prompt, cursor: cursor);
          break;
        case 'cell_edit':
          // the.cell.edit(row=, col_index=) — move focus to that cell
          // and initiate editing on it. Defaults to current selection.
          final r = (cmd['row'] as num?)?.toInt() ?? _selectedRow;
          final ci = (cmd['col_index'] as num?)?.toInt() ?? _selectedCol;
          final mode = cmd['mode'] as String?;
          final initialText = cmd['initial_text'] as String?;
          final prompt = cmd['prompt'] as String?;
          final cursor = cmd['cursor'] as String?;
          if (r >= 0 && r < _effectiveRowCount &&
              ci >= 0 && ci < _source.columnCount) {
            _moveTo(r, ci);
            _startEditing(codeMode: mode == 'code',
                initialText: initialText, prompt: prompt, cursor: cursor);
          }
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
    _etabKeyDiag('FIRED key=${event.logicalKey.debugName} '
        'editing=$_isEditing srcInit=$_sourceInitialized '
        'projLoaded=${_onKeyProjection != null} '
        'mpReady=${MicroPythonService.isReady}');
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
    final keyName = _logicalKeyName(key, event);
    if (_tryRunOnKeyProjection(keyName)) {
      return KeyEventResult.handled;
    }
    // Projection null / not ready / returned empty / threw — fall
    // through to baseline below. _tryRunOnKeyProjection has already
    // logged the cause via _etabKeyDiag.

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
        // ETB-06 Gap 2: shift+arrow must fire selection_change.
        final changed = row != _selEndRow;
        setState(() => _selEndRow = row);
        if (changed) _fireSelectionChange();
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
        // ETB-06 Gap 2: shift+arrow must fire selection_change.
        final changed = row != _selEndRow;
        setState(() => _selEndRow = row);
        if (changed) _fireSelectionChange();
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
        // ETB-06 Gap 2: shift+arrow must fire selection_change.
        final changed = col != _selEndCol;
        setState(() => _selEndCol = col);
        _ensureColumnVisible(col);
        if (changed) _fireSelectionChange();
      } else {
        _moveTo(_selectedRow, col);  // scroll: true → _ensureColumnVisible
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      final targetCol = isCtrl ? 0
          : (isShift ? _selEndCol - 1 : _selectedCol - 1);
      final col = targetCol.clamp(0, _source.columnCount - 1);
      if (isShift) {
        // ETB-06 Gap 2: shift+arrow must fire selection_change.
        final changed = col != _selEndCol;
        setState(() => _selEndCol = col);
        _ensureColumnVisible(col);
        if (changed) _fireSelectionChange();
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
        // ETB-06 Gap 2: shift+Home must fire selection_change.
        final changed = _selEndCol != 0;
        setState(() => _selEndCol = 0);
        _scrollToSelEnd();
        if (changed) _fireSelectionChange();
      } else {
        _moveTo(_selectedRow, 0);
      }
      handled = true;
    } else if (key == LogicalKeyboardKey.end) {
      final lastCol = _source.columnCount - 1;
      if (isShift) {
        // ETB-06 Gap 2: shift+End must fire selection_change.
        final changed = _selEndCol != lastCol;
        setState(() => _selEndCol = lastCol);
        _scrollToSelEnd();
        if (changed) _fireSelectionChange();
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
      // Character keys: check event.character for printable input.
      // Skip when Ctrl/Meta/Alt is held — a modified combo like Cmd+;
      // still reports event.character == ';', and treating it as
      // type-to-replace stole Cmd+; (group switch) into a cell edit.
      final char = event.character;
      if (char != null &&
          char.length == 1 &&
          char.codeUnitAt(0) >= 0x20 &&
          !isCtrl &&
          !HardwareKeyboard.instance.isAltPressed) {
        // Any printable character (>= space): type-to-replace
        _startEditing(initialText: char);
        handled = true;
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
  /// Then grows to fit the largest `the.cell.size` any cell in the row sets,
  /// so a bigger font isn't clipped (reuses the same render plane / per-cell
  /// size the cells already compute). Only called for BUILT rows (the visible
  /// window), so it never evaluates renders for the millions of unrendered
  /// rows that extentEstimation probes — LOD-safe.
  double _getRowHeight(int row) {
    final base =
        _pixelLodActive ? _cache.rowHeight(row) : _source.getRowHeight(row);
    if (_renderProjection == null) return base;
    double maxSize = 0;
    for (int c = 0; c < _source.columnCount; c++) {
      if (_source.isColumnHidden(c)) continue;
      final s = _evalCellRender(row, c)?['size']; // cached; reused by _buildCell
      final d = s == null ? null : double.tryParse(s);
      if (d != null && d > maxSize) maxSize = d;
    }
    if (maxSize <= 0) return base;
    // 1.4× the font covers the full line box (ascenders + descenders) so
    // glyph tails like g/y/p aren't clipped; then add vertical padding.
    final needed = maxSize * 1.4 + 2 * _source.cellPaddingV;
    return needed > base ? needed : base;
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
    // Merge user-pushed render context (e.g., setup-tier locals from
    // value_code, doc-level free names from cross-control references)
    // BEFORE the cell-context vars so cell-context wins on key conflicts.
    final ctlIdStr = widget.control.id?.toString();
    final pushedCtx = ctlIdStr == null
        ? null
        : RenderPlaneControl.getContext(ctlIdStr);
    final isAnchorCell = _isAnchor(rowIndex, colIndex);
    final colNameForCtx = colIndex < _source.columnCount
        ? _source.columnName(colIndex) : '';
    final ctx = <String, dynamic>{
      if (pushedCtx != null) ...pushedCtx,
      'value': cellValue,
      'row': cached?.rawData,
      'col_name': colNameForCtx,
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
      // E12 — symmetric interaction-state flags. Match the cell ctx
      // surface that EScalar / EInk also provide to render snippets.
      'is_editing': _isEditing && isAnchorCell,
      'is_focused': isAnchorCell,
      'is_overridden': _cache.hasOverride(rowIndex, colNameForCtx),
      'is_summary': false,
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
        // Extract property values + z-levels for cross-plane merge.
        // 'display' is the formatted cell text (cell.format / cell.display
        // on the prelude). It rides through the same map and overrides
        // the raw value when consumed by the cell builder.
        for (final prop in ['bg', 'color', 'weight', 'size', 'font',
                            'italic', 'tooltip', 'display']) {
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

  /// Evaluate the SAME render code for a summary-footer cell, with
  /// `is_summary` true. Lets `if the.cell.is_summary: the.cell.size = 28`
  /// style the footer through the identical render plane the data cells use.
  Map<String, String>? _evalSummaryRender(
      int colIndex, List<String> summaryValues) {
    if (_renderProjection == null || !MicroPythonService.isReady) return null;
    final key = 'summary:$colIndex';
    if (_cellRenderCache.containsKey(key)) return _cellRenderCache[key];

    final proj = _renderProjection!;
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String? ?? '';
    if (evalExpr.isEmpty) {
      _cellRenderCache[key] = null;
      return null;
    }
    final colName =
        colIndex < _source.columnCount ? _source.columnName(colIndex) : '';
    final cellValue =
        colIndex < summaryValues.length ? summaryValues[colIndex] : '';
    final ctlIdStr = widget.control.id?.toString();
    final pushedCtx =
        ctlIdStr == null ? null : RenderPlaneControl.getContext(ctlIdStr);
    final ctx = <String, dynamic>{
      if (pushedCtx != null) ...pushedCtx,
      'value': cellValue,
      'row': summaryValues,
      'col_name': colName,
      'col_index': colIndex,
      'row_index': _effectiveRowCount, // footer sits after the last data row
      'is_selected': false,
      'is_hovered': false,
      'is_hovered_cell': false,
      'hovered_col': -1,
      'total_rows': _effectiveRowCount,
      'total_cols': _source.columnCount,
      'viewport_pos': 0,
      'viewport_count': 1,
      'is_editing': false,
      'is_focused': false,
      'is_overridden': false,
      'is_summary': true,
    };
    try {
      final config = MicroPythonService.execEval(
          'cell._reset()\n$execBody\n$evalExpr\n', 'cell._to_config()', ctx);
      if (config is Map && config.isNotEmpty) {
        final style = <String, String>{};
        for (final prop in ['bg', 'color', 'weight', 'size', 'font',
                            'italic', 'tooltip', 'display']) {
          if (config[prop] != null) {
            final dartKey = prop == 'color' ? 'fg' : prop;
            style[dartKey] = config[prop].toString();
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

  /// Prepend an Icon (Material name) to a cell's text, sized to match the
  /// cell font. Falls through unchanged when [iconName] is null/empty.
  Widget _wrapIcon(String? iconName, Widget textChild,
                   Color? color, double size) {
    if (iconName == null || iconName.isEmpty) return textChild;
    final iconData = _resolveIcon(iconName);
    if (iconData == null) return textChild;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(iconData, size: size, color: color),
        const SizedBox(width: 4),
        Flexible(child: textChild),
      ],
    );
  }

  /// Map a string name to a Material IconData. Names match common Material
  /// icon identifiers ('star', 'check', 'warning', etc.). Unknown names
  /// return null so the cell renders text-only.
  IconData? _resolveIcon(String name) {
    switch (name.toLowerCase()) {
      case 'star':       return Icons.star;
      case 'star_border': return Icons.star_border;
      case 'check':      return Icons.check;
      case 'check_circle': return Icons.check_circle;
      case 'close':      return Icons.close;
      case 'cancel':     return Icons.cancel;
      case 'warning':    return Icons.warning;
      case 'error':      return Icons.error;
      case 'info':       return Icons.info;
      case 'help':       return Icons.help;
      case 'add':        return Icons.add;
      case 'remove':     return Icons.remove;
      case 'arrow_up':
      case 'up':         return Icons.arrow_upward;
      case 'arrow_down':
      case 'down':       return Icons.arrow_downward;
      case 'flag':       return Icons.flag;
      case 'lock':       return Icons.lock;
      case 'unlock':     return Icons.lock_open;
      case 'edit':       return Icons.edit;
      case 'delete':     return Icons.delete;
      case 'search':     return Icons.search;
      case 'refresh':    return Icons.refresh;
      case 'visibility': return Icons.visibility;
      case 'visibility_off': return Icons.visibility_off;
      default: return null;
    }
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


/// ETB-19 marching ants — animated dashed outline around every cell the
/// user has picked into the open cell-formula popup (Excel pattern).
/// `rects` are in the SuperListView's viewport coordinate space, supplied
/// by `_pickedCellViewportRect`. `phase` advances 0→1 each animation
/// cycle and is reduced modulo the dash length to slide the dashes.
class _MarchingAntsPainter extends CustomPainter {
  _MarchingAntsPainter({
    required this.picks,
    required this.animation,
    required this.resolveRect,
    Listenable? extraRepaint,
  }) : super(
            repaint: extraRepaint == null
                ? animation
                : Listenable.merge([animation, extraRepaint]));

  final List<({int row, String col})> picks;
  // Read `.value` at paint time — capturing it at build time would
  // freeze the phase and the dashes wouldn't march.
  final Animation<double> animation;
  // Re-resolved at every paint so cell rects track scroll. (Build-time
  // rects froze the dashes at whatever scroll offset was current when
  // the widget was built; CustomPaint's repaint Listenable only marks
  // the RenderObject dirty for paint, not for build.)
  final Rect? Function(int row, String col) resolveRect;
  static const double _dash = 6.0;
  static const double _gap = 4.0;
  static const double _stroke = 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    if (picks.isEmpty) return;
    final period = _dash + _gap;
    final phasePx = animation.value * period;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..color = const Color(0xFF57C66B); // Neovim green
    // Clip to viewport so dashes never bleed over chrome.
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final p in picks) {
      final r = resolveRect(p.row, p.col);
      if (r == null) continue;
      // Draw the four sides as dashed segments, each starting from a
      // phase-shifted offset so all four scroll in the same direction.
      _drawDashedLine(canvas, paint, r.topLeft, r.topRight, phasePx, period);
      _drawDashedLine(canvas, paint, r.topRight, r.bottomRight, phasePx, period);
      _drawDashedLine(
          canvas, paint, r.bottomRight, r.bottomLeft, phasePx, period);
      _drawDashedLine(canvas, paint, r.bottomLeft, r.topLeft, phasePx, period);
    }
    canvas.restore();
  }

  void _drawDashedLine(Canvas canvas, Paint paint, Offset a, Offset b,
      double phasePx, double period) {
    final delta = b - a;
    final length = delta.distance;
    if (length == 0) return;
    final dir = delta / length;
    // Start at -phasePx so dashes slide in the +direction.
    double t = -phasePx;
    while (t < length) {
      final segStart = math.max(t, 0.0);
      final segEnd = math.min(t + _dash, length);
      if (segEnd > segStart) {
        canvas.drawLine(a + dir * segStart, a + dir * segEnd, paint);
      }
      t += period;
    }
  }

  @override
  // Repaints are driven by the `repaint` Listenable (animation + scroll).
  // When CustomPaint diffs us against an old painter (only on widget
  // rebuild), accept the swap whenever the pick set changed shape.
  bool shouldRepaint(covariant _MarchingAntsPainter old) =>
      picks.length != old.picks.length || !_samePicks(picks, old.picks);

  static bool _samePicks(
      List<({int row, String col})> a, List<({int row, String col})> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].row != b[i].row || a[i].col != b[i].col) return false;
    }
    return true;
  }
}
