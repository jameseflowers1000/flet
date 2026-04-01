// Flutter widget tests for EpyxGrid — verifies ACTUAL RENDERING.
//
// These tests build the EpyxGrid widget with mock data and verify
// that cell text appears in the widget tree using `find.text()`.
//
// If these tests fail, the grid is not rendering data — period.
// No amount of Python-side testing can substitute for this.

import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flet_supertab/src/epyx_grid.dart';

/// Create a mock Control with the given properties.
/// This simulates what Flet sends from Python.
Control _mockControl(Map<String, dynamic> props) {
  final backend = _MockFletBackend();
  return Control(
    id: 1,
    type: 'flet_supertab',
    properties: props,
    backend: backend,
  );
}

/// Minimal mock of FletBackend for testing. All methods are no-ops.
class _MockFletBackend implements FletBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Build known column/row JSON matching what Python _sync_to_control sends.
Map<String, dynamic> _gridProps({
  List<Map<String, dynamic>>? columns,
  List<List<dynamic>>? rows,
  int totalRows = 0,
  String label = '',
  String ctype = '',
}) {
  final cols = columns ??
      [
        {'name': 'item', 'label': 'Item', 'dtype': 'str', 'format': '', 'read_only': false, 'alignment': 'centerLeft'},
        {'name': 'amount', 'label': 'Amount', 'dtype': 'float', 'format': '', 'read_only': false, 'alignment': 'centerRight'},
      ];
  final data = rows ??
      [
        ['Rent', '1500.00'],
        ['Food', '300.00'],
        ['Transport', '50.00'],
      ];

  return {
    'columns': jsonEncode(cols),
    'rows': jsonEncode(data),
    'total_rows': totalRows > 0 ? totalRows : data.length,
    'label': label,
    'ctype': ctype,
    'row_height': 36.0,
    'header_row_height': 40.0,
    'cell_font_size': 13.0,
    'header_font_size': 13.0,
    'grid_line_width': 1.0,
    'current_cell_border_width': 2.0,
    'cell_padding_horizontal': 12.0,
    'cell_padding_vertical': 4.0,
  };
}

void main() {
  group('EpyxGrid renders cell data', () {
    testWidgets('renders cell text from rows JSON', (tester) async {
      final control = _mockControl(_gridProps());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // THE CRITICAL ASSERTION: cell text must exist in the widget tree
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('1500.00'), findsOneWidget);
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('300.00'), findsOneWidget);
    });

    testWidgets('renders column headers', (tester) async {
      final control = _mockControl(_gridProps());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Item'), findsOneWidget);
      expect(find.text('Amount'), findsOneWidget);
    });

    testWidgets('renders header label and ctype badge', (tester) async {
      final control = _mockControl(_gridProps(
        label: 'Monthly Expenses',
        ctype: 'comparison',
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Monthly Expenses'), findsOneWidget);
      expect(find.text('comparison'), findsOneWidget);
    });

    testWidgets('renders "No data" when rows empty', (tester) async {
      final control = _mockControl(_gridProps(rows: []));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No data'), findsOneWidget);
    });

    testWidgets('renders Semantics labels on cells', (tester) async {
      final control = _mockControl(_gridProps());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Semantics labels follow pattern: cell_{row}_{col}_{text}
      expect(
        find.bySemanticsLabel(RegExp(r'cell_0_0_Rent')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'cell_0_1_1500\.00')),
        findsOneWidget,
      );
    });

    testWidgets('renders correct number of rows', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [
          ['A', '1'],
          ['B', '2'],
          ['C', '3'],
          ['D', '4'],
          ['E', '5'],
        ],
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
    });
  });
}
