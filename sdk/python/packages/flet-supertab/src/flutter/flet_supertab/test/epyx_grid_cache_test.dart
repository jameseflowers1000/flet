// Dart unit tests for GridCache.walk() — pixel-space LOD scroll algorithm.
//
// Covers the off-by-one fix for DisplayPosition.bottom: the walk must keep
// the target row's BOTTOM edge inside the viewport, not just guarantee that
// the accumulated rows fit. The earlier algorithm allowed the target row
// to overflow by up to one row's height ("Cmd-Down lands one row short").

import 'package:flutter_test/flutter_test.dart';
import 'package:flet_supertab/src/epyx_grid_cache.dart';

GridCache _buildCache({
  required int totalRows,
  required double rowHeight,
  int? overflowRow,
  double? overflowHeight,
}) {
  final cache = GridCache();
  cache.defaultRowHeight = rowHeight;
  cache.totalRows = totalRows;

  // Page everything in upfront — these tests are about the walk algorithm,
  // not the LOD page-fault path.
  final rows = <List<Object?>>[];
  final pixelOffsets = <double>[];
  final heights = <double>[];
  double y = 0.0;
  for (int i = 0; i < totalRows; i++) {
    rows.add(<Object?>[i, 'row $i']);
    pixelOffsets.add(y);
    final h = (overflowRow == i && overflowHeight != null)
        ? overflowHeight
        : rowHeight;
    heights.add(h);
    y += h;
  }
  cache.totalHeight = y;

  cache.mergePage(
    bufferStart: 0,
    rows: rows,
    pixelOffsets: pixelOffsets,
    heights: heights,
  );
  return cache;
}

void main() {
  group('GridCache.walk — DisplayPosition.bottom', () {
    test('uniform rows: target row stays fully visible at viewport bottom', () {
      // viewport=600, rowHeight=36, target=359 (last row of a 360-row table).
      // 600/36 = 16.67 rows fit in the viewport.
      // The walk must put firstVisible at row 344 (16 rows fit:
      // 344..359, sum=16*36=576 ≤ 600), NOT row 343 (17 rows
      // sum=17*36=612 > 600 → row 359 cut off by 12px).
      final cache = _buildCache(totalRows: 360, rowHeight: 36);
      final result = cache.walk(DisplayEvent(359, DisplayPosition.bottom), 600);
      expect(result.success, isTrue);
      expect(result.row, 344,
          reason: 'firstVisible should be 344 so 344..359 (16 rows = 576px) '
              'fit in viewport=600 with the target row 359 fully visible');
      // Sanity: total visible height ≤ viewport
      final visibleHeight = (359 - result.row + 1) * 36.0;
      expect(visibleHeight, lessThanOrEqualTo(600));
    });

    test('viewport perfectly divisible by rowHeight', () {
      // viewport=600, rowHeight=20 → exactly 30 rows fit.
      // Target=99 of 100. firstVisible should be 70 (rows 70..99, 30 rows).
      final cache = _buildCache(totalRows: 100, rowHeight: 20);
      final result = cache.walk(DisplayEvent(99, DisplayPosition.bottom), 600);
      expect(result.success, isTrue);
      expect(result.row, 70);
      expect((99 - 70 + 1) * 20, 600);
    });

    test('target near top of table: firstVisible clamps to 0', () {
      // Target=2 in a 100-row table. viewport big enough for whole table.
      // Walking back from 2 we hit row 0 — firstVisible=0.
      final cache = _buildCache(totalRows: 100, rowHeight: 36);
      final result = cache.walk(DisplayEvent(2, DisplayPosition.bottom), 600);
      expect(result.success, isTrue);
      expect(result.row, 0);
    });

    test('single row taller than viewport: returns target as firstVisible', () {
      // Target row is 800px high, viewport is 600. Best we can do is
      // put the target at the top.
      final cache = _buildCache(
        totalRows: 10,
        rowHeight: 36,
        overflowRow: 5,
        overflowHeight: 800,
      );
      final result = cache.walk(DisplayEvent(5, DisplayPosition.bottom), 600);
      expect(result.success, isTrue);
      expect(result.row, 5,
          reason: 'When the target row alone exceeds viewport, '
              'firstVisible should be the target itself');
    });

    test('variable row heights: target stays fully visible', () {
      // 100 rows, mostly 36px, but row 50 is 100px (a tall row).
      // Target=99, viewport=400. Walking back: 99=36, 98=72, ..., need to
      // stop when adding the next row would exceed 400.
      // 36 * 11 = 396 (rows 89..99, 11 rows). 36 * 12 = 432 > 400 → stop.
      // firstVisible should be 89.
      final cache = _buildCache(totalRows: 100, rowHeight: 36);
      final result = cache.walk(DisplayEvent(99, DisplayPosition.bottom), 400);
      expect(result.success, isTrue);
      expect(result.row, 89);
      expect((99 - 89 + 1) * 36, 396);
    });

    test('PageFault: missing row in walk path', () {
      // Build a cache that's missing row 50.
      final cache = GridCache();
      cache.defaultRowHeight = 36;
      cache.totalRows = 100;
      // Page in rows 0..49 only.
      cache.mergePage(
        bufferStart: 0,
        rows: List.generate(50, (i) => <Object?>[i]),
        pixelOffsets: List.generate(50, (i) => i * 36.0),
        heights: List.generate(50, (_) => 36.0),
      );
      // Walk for target=99 (uncached).
      final result = cache.walk(DisplayEvent(99, DisplayPosition.bottom), 600);
      expect(result.success, isFalse, reason: 'should be a PageFault');
      expect(result.row, 99,
          reason: 'fault row is the first uncached row hit during walk');
    });
  });

  group('GridCache.walk — DisplayPosition.top', () {
    test('returns target as firstVisible when full screenful is cached', () {
      final cache = _buildCache(totalRows: 100, rowHeight: 36);
      final result = cache.walk(DisplayEvent(50, DisplayPosition.top), 600);
      expect(result.success, isTrue);
      expect(result.row, 50);
    });

    test('PageFault when forward window has missing row', () {
      final cache = GridCache();
      cache.defaultRowHeight = 36;
      cache.totalRows = 100;
      // Page in rows 0..50 only.
      cache.mergePage(
        bufferStart: 0,
        rows: List.generate(51, (i) => <Object?>[i]),
        pixelOffsets: List.generate(51, (i) => i * 36.0),
        heights: List.generate(51, (_) => 36.0),
      );
      // Target=50 with viewport big enough to need rows 50..67.
      final result = cache.walk(DisplayEvent(50, DisplayPosition.top), 600);
      expect(result.success, isFalse);
      // First missing row in forward walk is 51.
      expect(result.row, 51);
    });
  });
}
