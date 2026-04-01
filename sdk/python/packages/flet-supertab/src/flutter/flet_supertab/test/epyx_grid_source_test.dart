// Dart unit tests for EpyxGridSource — data model parsing and formatting.
//
// These test the data layer WITHOUT rendering widgets.
// Covers: P1 checklist items for data model parsing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flet_supertab/src/epyx_grid_source.dart';

void main() {
  group('EpyxGridSource construction', () {
    test('empty source has zero rows and columns', () {
      final source = EpyxGridSource(
        columns: [],
        columnNames: [],
        columnLabels: [],
        columnDtypes: [],
        columnWidths: [],
        rows: [],
      );

      expect(source.rowCount, 0);
      expect(source.columnCount, 0);
    });

    test('parses columns and rows correctly', () {
      final source = EpyxGridSource(
        columns: [
          {'name': 'month', 'dtype': 'int', 'label': 'Month'},
          {'name': 'payment', 'dtype': 'float', 'label': 'Payment'},
          {'name': 'status', 'dtype': 'str', 'label': 'Status'},
        ],
        columnNames: ['month', 'payment', 'status'],
        columnLabels: ['Month', 'Payment', 'Status'],
        columnDtypes: ['int', 'float', 'str'],
        columnWidths: [80, 120, 100],
        rows: [
          ['1', '1073.64', 'active'],
          ['2', '1073.64', 'active'],
          ['3', '1073.64', 'paid'],
        ],
      );

      expect(source.rowCount, 3);
      expect(source.columnCount, 3);
      expect(source.columnName(0), 'month');
      expect(source.columnLabel(1), 'Payment');
    });
  });

  group('cell text', () {
    late EpyxGridSource source;

    setUp(() {
      source = EpyxGridSource(
        columns: [
          {'name': 'a', 'dtype': 'int'},
          {'name': 'b', 'dtype': 'float'},
        ],
        columnNames: ['a', 'b'],
        columnLabels: ['A', 'B'],
        columnDtypes: ['int', 'float'],
        columnWidths: [100, 100],
        rows: [
          ['42', '3.14'],
          ['0', 'NaN'],
          [null, 'Inf'],
        ],
      );
    });

    test('returns cell value as string', () {
      expect(source.cellText(0, 0), '42');
      expect(source.cellText(0, 1), '3.14');
    });

    test('returns empty string for null', () {
      expect(source.cellText(2, 0), '');
    });

    test('handles NaN and Inf as strings', () {
      expect(source.cellText(1, 1), 'NaN');
      expect(source.cellText(2, 1), 'Inf');
    });

    test('returns empty for out-of-bounds row', () {
      expect(source.cellText(99, 0), '');
    });

    test('returns empty for out-of-bounds column', () {
      expect(source.cellText(0, 99), '');
    });
  });

  group('dtype-aware alignment', () {
    test('int and float are numeric', () {
      final source = EpyxGridSource(
        columns: [
          {'name': 'x', 'dtype': 'int'},
          {'name': 'y', 'dtype': 'float'},
          {'name': 'z', 'dtype': 'str'},
          {'name': 'w', 'dtype': 'bool'},
        ],
        columnNames: ['x', 'y', 'z', 'w'],
        columnLabels: ['X', 'Y', 'Z', 'W'],
        columnDtypes: ['int', 'float', 'str', 'bool'],
        columnWidths: [100, 100, 100, 100],
        rows: [],
      );

      expect(source.isNumericColumn(0), true);
      expect(source.isNumericColumn(1), true);
      expect(source.isNumericColumn(2), false);
      expect(source.isNumericColumn(3), false);
    });

    test('out-of-bounds column is not numeric', () {
      final source = EpyxGridSource(
        columns: [],
        columnNames: [],
        columnLabels: [],
        columnDtypes: [],
        columnWidths: [],
        rows: [],
      );

      expect(source.isNumericColumn(0), false);
    });
  });

  group('cell styles', () {
    test('returns null for no styles', () {
      final source = EpyxGridSource(
        columns: [{'name': 'x'}],
        columnNames: ['x'],
        columnLabels: ['X'],
        columnDtypes: ['str'],
        columnWidths: [100],
        rows: [['hello']],
      );

      expect(source.cellStyle(0, 0), isNull);
    });

    test('returns style dict when present', () {
      final source = EpyxGridSource(
        columns: [{'name': 'x'}],
        columnNames: ['x'],
        columnLabels: ['X'],
        columnDtypes: ['str'],
        columnWidths: [100],
        rows: [['hello']],
        cellStyles: [
          [{'bg': '#ff0000', 'fg': '#ffffff'}]
        ],
      );

      final style = source.cellStyle(0, 0);
      expect(style, isNotNull);
      expect(style!['bg'], '#ff0000');
      expect(style['fg'], '#ffffff');
    });

    test('returns null for out-of-bounds style', () {
      final source = EpyxGridSource(
        columns: [{'name': 'x'}],
        columnNames: ['x'],
        columnLabels: ['X'],
        columnDtypes: ['str'],
        columnWidths: [100],
        rows: [['hello']],
        cellStyles: [],
      );

      expect(source.cellStyle(0, 0), isNull);
    });
  });

  group('row background', () {
    test('selected row uses selection color', () {
      final source = EpyxGridSource(
        columns: [],
        columnNames: [],
        columnLabels: [],
        columnDtypes: [],
        columnWidths: [],
        rows: [],
        selectionColor: const Color(0x262196F3),
      );

      expect(source.rowBackground(0, true), const Color(0x262196F3));
    });

    test('odd row uses alternate color when set', () {
      final source = EpyxGridSource(
        columns: [],
        columnNames: [],
        columnLabels: [],
        columnDtypes: [],
        columnWidths: [],
        rows: [],
        alternateRowColor: const Color(0xFF1A1A2E),
      );

      expect(source.rowBackground(0, false), isNull); // even
      expect(source.rowBackground(1, false), const Color(0xFF1A1A2E)); // odd
    });

    test('no alternate color returns null for non-selected', () {
      final source = EpyxGridSource(
        columns: [],
        columnNames: [],
        columnLabels: [],
        columnDtypes: [],
        columnWidths: [],
        rows: [],
      );

      expect(source.rowBackground(0, false), isNull);
      expect(source.rowBackground(1, false), isNull);
    });
  });

  group('column widths', () {
    test('default width for missing column', () {
      final source = EpyxGridSource(
        columns: [],
        columnNames: [],
        columnLabels: [],
        columnDtypes: [],
        columnWidths: [],
        rows: [],
      );

      expect(source.columnWidth(0), 120.0);
    });

    test('returns stored width', () {
      final source = EpyxGridSource(
        columns: [{'name': 'x'}],
        columnNames: ['x'],
        columnLabels: ['X'],
        columnDtypes: ['str'],
        columnWidths: [200],
        rows: [],
      );

      expect(source.columnWidth(0), 200.0);
    });

    test('last column fills available width', () {
      final source = EpyxGridSource(
        columns: [
          {'name': 'a'},
          {'name': 'b'},
        ],
        columnNames: ['a', 'b'],
        columnLabels: ['A', 'B'],
        columnDtypes: ['str', 'str'],
        columnWidths: [100, 100],
        rows: [],
      );

      source.setAvailableWidth(500);
      expect(source.columnWidth(0), 100.0); // first column unchanged
      expect(source.columnWidth(1), 400.0); // last column fills: 500 - 100
    });
  });
}
