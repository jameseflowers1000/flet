/// Pixel-space LOD cache for EpyxGrid.
///
/// Stores rows keyed by absolute index along with their pixel offsets.
/// The render plane asks this cache "do you have row N?" and gets back
/// the row data + its pixel position for scrolling.
///
/// The logic plane provides:
///   - total_rows, total_height (via control properties)
///   - page responses with rows + pixel_offsets (via page_request events)
///
/// Display events (Cmd-Down, scroll, go-to) are queued.  The queue is
/// processed by walking from the target row; if any row is missing
/// (PageFault), a page request is issued and the event stays on the queue.
/// When the page arrives, the queue is retried.

import 'dart:convert';
import 'dart:math' as math;

/// A single cached row: its data, pixel offset, height, and storage index.
class CachedRow {
  final List<Object?> data;      // display-formatted strings
  final List<Object?> rawData;   // raw values (numbers, for render plane)
  final double pixelOffset;       // top of this row in pixel space
  final double height;
  final int storageIndex;         // original storage-space row index
  int lastAccess;                 // monotonic counter for LRU eviction

  CachedRow(this.data, this.rawData, this.pixelOffset, this.height,
      this.storageIndex, [this.lastAccess = 0]);
}

/// Display event types.
enum DisplayPosition { top, bottom, center }

/// A pending display event: "show targetRow at position."
class DisplayEvent {
  final int targetRow;
  final DisplayPosition position;
  DisplayEvent(this.targetRow, this.position);
}

/// The pixel-space row cache.
class GridCache {
  final Map<int, CachedRow> _rows = {};
  final Map<int, List<Map<String, String>?>> _cellStyles = {};
  final Set<String> _overrides = {}; // "absRow:colName" keys
  // Sparse height overrides: only rows with non-default height.
  // itemExtentBuilder checks this (O(1) per call) instead of the full cache.
  final Map<int, double> _heightOverrides = {};

  double defaultRowHeight = 36.0;
  int totalRows = 0;
  double totalHeight = 0.0;
  int _accessCounter = 0; // monotonic counter for LRU

  /// Number of cached rows.
  int get cachedRowCount => _rows.length;

  /// Iterate over all cached rows (for auto-size, etc.).
  Iterable<MapEntry<int, CachedRow>> get cachedEntries => _rows.entries;

  /// Is this absolute row in the cache?
  bool has(int absRow) => _rows.containsKey(absRow);

  /// Get a cached row (or null). Updates LRU access time.
  CachedRow? get(int absRow) {
    final row = _rows[absRow];
    if (row != null) row.lastAccess = ++_accessCounter;
    return row;
  }

  /// Get the pixel offset for a cached row.
  double? pixelOffset(int absRow) => _rows[absRow]?.pixelOffset;

  /// Get the height of a row (cached or default).
  double rowHeight(int absRow) => _rows[absRow]?.height ?? defaultRowHeight;

  /// Fast height for itemExtentBuilder — O(1) sparse lookup, no full cache scan.
  double fastRowHeight(int absRow) => _heightOverrides[absRow] ?? defaultRowHeight;

  /// Are there any height overrides?
  bool get hasHeightOverrides => _heightOverrides.isNotEmpty;

  /// Set a height override for a row (from upfront Python push).
  void setHeightOverride(int absRow, double height) {
    _heightOverrides[absRow] = height;
  }

  /// Clear all height overrides (before re-applying from Python).
  void clearHeightOverrides() {
    _heightOverrides.clear();
  }

  /// Cell styles for a row (or null).
  List<Map<String, String>?>? cellStyles(int absRow) => _cellStyles[absRow];

  /// Does this cell have an override?
  bool hasOverride(int absRow, String colName) =>
      _overrides.contains('$absRow:$colName');

  /// Merge a page response into the cache.
  void mergePage({
    required int bufferStart,
    required List<List<Object?>> rows,
    required List<double> pixelOffsets,
    required List<double> heights,
    List<int>? storageIndices,
    List<List<Object?>>? rawRows,
    List<List<Map<String, String>?>>? cellStyles,
    List<String>? overrideCells,
  }) {
    // Clear stale overrides in this page range before adding fresh ones
    final pageEnd = bufferStart + rows.length;
    _overrides.removeWhere((key) {
      final colonIdx = key.indexOf(':');
      if (colonIdx < 0) return false;
      final row = int.tryParse(key.substring(0, colonIdx));
      return row != null && row >= bufferStart && row < pageEnd;
    });

    final ts = ++_accessCounter;
    for (int i = 0; i < rows.length; i++) {
      final absRow = bufferStart + i;
      final h = i < heights.length ? heights[i] : defaultRowHeight;
      final raw = (rawRows != null && i < rawRows.length)
          ? rawRows[i] : rows[i];
      _rows[absRow] = CachedRow(
        rows[i],
        raw,
        i < pixelOffsets.length ? pixelOffsets[i] : absRow * defaultRowHeight,
        h,
        storageIndices != null && i < storageIndices.length
            ? storageIndices[i] : absRow,
        ts,
      );
      // Track non-default heights in sparse map for O(1) itemExtentBuilder
      if ((h - defaultRowHeight).abs() > 0.01) {
        _heightOverrides[absRow] = h;
      } else {
        _heightOverrides.remove(absRow);
      }
      if (cellStyles != null && i < cellStyles.length) {
        _cellStyles[absRow] = cellStyles[i];
      }
    }
    if (overrideCells != null) {
      _overrides.addAll(overrideCells);
    }
  }

  /// LRU eviction: evict least-recently-accessed rows to keep cache bounded.
  /// Only runs when totalRows > 5000 and cache exceeds maxRows.
  void evictIfNeeded({
    required int maxPages,
    required int pageSize,
  }) {
    if (totalRows < 5000) return; // small tables: no eviction
    final maxRows = maxPages * pageSize;
    if (_rows.length <= maxRows) return;

    // Sort by lastAccess ascending (oldest first)
    final entries = _rows.entries.toList()
      ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));

    // Evict oldest until we're under the cap
    final toEvict = entries.length - maxRows;
    for (int i = 0; i < toEvict; i++) {
      final row = entries[i].key;
      _rows.remove(row);
      _cellStyles.remove(row);
    }
  }

  /// Clear all cached data (on column structure change or data invalidation).
  void clear() {
    _rows.clear();
    _cellStyles.clear();
    _overrides.clear();
    _heightOverrides.clear();
    displayQueue.clear();
  }

  /// The display event queue.
  final List<DisplayEvent> displayQueue = [];

  /// Enqueue a display event and try processing.
  void enqueue(DisplayEvent event) {
    displayQueue.add(event);
  }

  /// Walk from targetRow to find the first row to display.
  /// Returns the first visible row index, or null on PageFault.
  /// On PageFault, sets [faultRow] to the missing row.
  WalkResult walk(DisplayEvent event, double viewportHeight) {
    switch (event.position) {
      case DisplayPosition.bottom:
        // Walk backward from targetRow, growing the visible window as long
        // as adding the next row keeps the window ≤ viewportHeight. The
        // invariant is: sum(firstVisible..targetRow) ≤ viewportHeight, so
        // the target row's BOTTOM stays inside the viewport.
        //
        // Earlier version returned r the moment `accumulated >= viewport`,
        // which guaranteed the rows fit but allowed the target row's
        // bottom to OVERFLOW by up to one row's height — visible as
        // "Cmd-Down lands one row short" because the last row's last
        // pixels were hidden under the bottom edge.
        if (!has(event.targetRow)) return WalkResult.fault(event.targetRow);
        double accumulated = rowHeight(event.targetRow);
        // Edge case: a single row that's already taller than the viewport.
        // Just put it at the top — best we can do.
        if (accumulated >= viewportHeight) {
          return WalkResult.success(event.targetRow);
        }
        int firstVisible = event.targetRow;
        for (int r = event.targetRow - 1; r >= 0; r--) {
          if (!has(r)) return WalkResult.fault(r);
          final h = rowHeight(r);
          // Stop one row early — adding this would overflow the viewport.
          // firstVisible stays at the previous (later) row.
          if (accumulated + h > viewportHeight) break;
          accumulated += h;
          firstVisible = r;
        }
        return WalkResult.success(firstVisible);

      case DisplayPosition.top:
        // Verify a screenful forward from targetRow
        double accumulated = 0;
        for (int r = event.targetRow; r < totalRows; r++) {
          if (!has(r)) return WalkResult.fault(r);
          accumulated += rowHeight(r);
          if (accumulated >= viewportHeight) break;
        }
        return WalkResult.success(event.targetRow);

      case DisplayPosition.center:
        if (!has(event.targetRow)) {
          return WalkResult.fault(event.targetRow);
        }
        double halfH = viewportHeight / 2;
        int firstRow = event.targetRow;
        double acc = rowHeight(event.targetRow) / 2;
        // Walk backward
        for (int r = event.targetRow - 1; r >= 0 && acc < halfH; r--) {
          if (!has(r)) return WalkResult.fault(r);
          acc += rowHeight(r);
          firstRow = r;
        }
        // Verify forward
        acc = rowHeight(event.targetRow) / 2;
        for (int r = event.targetRow + 1; r < totalRows && acc < halfH; r++) {
          if (!has(r)) return WalkResult.fault(r);
          acc += rowHeight(r);
        }
        return WalkResult.success(firstRow);
    }
  }
}

/// Result of a cache walk: either success (firstRow to display)
/// or fault (missing row that needs fetching).
class WalkResult {
  final bool success;
  final int row; // firstRow on success, faultRow on fault

  WalkResult.success(this.row) : success = true;
  WalkResult.fault(this.row) : success = false;
}
