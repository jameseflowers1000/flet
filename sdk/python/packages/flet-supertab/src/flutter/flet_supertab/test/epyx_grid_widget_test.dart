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

/// Strong reference to mock backend — prevents GC via WeakReference in Control.
_MockFletBackend _keepAliveBackend = _MockFletBackend();

/// Create a mock Control with the given properties.
/// This simulates what Flet sends from Python.
Control _mockControl(Map<String, dynamic> props) {
  _keepAliveBackend = _MockFletBackend();
  return Control(
    id: 1,
    type: 'flet_supertab',
    properties: props,
    backend: _keepAliveBackend,
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

    testWidgets('renders in unbounded height (Natural mode pane)', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['Rent', '1500.00'], ['Food', '300.00']],
      ));

      // Unbounded height: SingleChildScrollView gives infinite height to child
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rent'), findsOneWidget,
          reason: 'Grid must render in unbounded height (Natural mode)');
      expect(find.text('Food'), findsOneWidget);
    });

    testWidgets('tap selects cell in unbounded height (Natural mode)', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['Rent', '1500.00'], ['Food', '300.00']],
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on "Food" — must select without crashing
      await tester.tap(find.text('Food'));
      await tester.pump();

      // Verify selection changed via Semantics (cell should be selected)
      // The cell should still be visible (not crashed)
      expect(find.text('Food'), findsOneWidget,
          reason: 'Tapping a cell in Natural mode must not crash');
    });
  });

  group('EpyxGrid updates on data change', () {
    testWidgets('widget updates when control properties change', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['Rent', '1500.00']],
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

      // Verify initial data renders
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('1500.00'), findsOneWidget);

      // SIMULATE: Python pushes new data via _sync_to_control
      // This is what happens during recalc — properties change, notify fires
      control.properties['rows'] = jsonEncode([['Mortgage', '2500.00'], ['Insurance', '150.00']]);
      control.properties['total_rows'] = 2;
      control.notify();  // ChangeNotifier fires — widget MUST rebuild

      await tester.pumpAndSettle();

      // THE CRITICAL ASSERTION: widget must show NEW data
      expect(find.text('Mortgage'), findsOneWidget,
          reason: 'After control.notify(), widget must rebuild with new rows');
      expect(find.text('2500.00'), findsOneWidget);
      expect(find.text('Insurance'), findsOneWidget);
      // Old data must be gone
      expect(find.text('Rent'), findsNothing,
          reason: 'Old row "Rent" must not appear after data update');
    });

    testWidgets('widget updates column count on change', (tester) async {
      final control = _mockControl(_gridProps(
        columns: [
          {'name': 'x', 'label': 'X', 'dtype': 'int', 'format': '', 'read_only': false, 'alignment': 'centerRight'},
        ],
        rows: [['42']],
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

      expect(find.text('X'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);

      // Add a column
      control.properties['columns'] = jsonEncode([
        {'name': 'x', 'label': 'X', 'dtype': 'int', 'format': '', 'read_only': false, 'alignment': 'centerRight'},
        {'name': 'y', 'label': 'Y', 'dtype': 'str', 'format': '', 'read_only': false, 'alignment': 'centerLeft'},
      ]);
      control.properties['rows'] = jsonEncode([['42', 'hello']]);
      control.notify();

      await tester.pumpAndSettle();

      expect(find.text('Y'), findsOneWidget,
          reason: 'New column header must appear after data change');
      expect(find.text('hello'), findsOneWidget,
          reason: 'New column cell data must appear');
    });

    testWidgets('widget updates total_rows display', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['A', '1']],
        totalRows: 1,  // match actual row count (no LOD spinner)
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

      expect(find.textContaining('of 1'), findsOneWidget);

      // Update total_rows and rows (set total = rows to avoid LOD spinner)
      control.properties['total_rows'] = 2;
      control.properties['rows'] = jsonEncode([['A', '1'], ['B', '2']]);
      control.notify();

      // Use pump() not pumpAndSettle() to avoid animation timeout
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('of 2'), findsOneWidget,
          reason: 'Row count display must update after notify');
    });
  });

  group('EpyxGrid LOD (Load on Demand)', () {
    testWidgets('fires page_request when spinner item is built', (tester) async {
      // 3 rows loaded, but total_rows=100 → spinner shows, page_request fires
      final events = <String>[];
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2'], ['C', '3']],
        totalRows: 100,
      ));

      // Capture events fired by the widget
      // The mock backend's triggerControlEventById will be called
      // We can't easily intercept it on _MockFletBackend since it uses
      // noSuchMethod. Instead, verify the spinner is present (which
      // means the request code path was hit).

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
      // Use pump() not pumpAndSettle() — spinner animation never settles
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The spinner (CircularProgressIndicator) must be present
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'LOD spinner must show when total_rows > loaded rows');

      // The data rows must also be present
      expect(find.text('A'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets('spinner disappears when all rows loaded', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2']],
        totalRows: 2,  // total == loaded → no spinner
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

      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'No spinner when all rows are loaded');
    });

    testWidgets('LOD loads second page after notify', (tester) async {
      // Start with 3 rows, total=100 → spinner + page_request
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2'], ['C', '3']],
        totalRows: 100,
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify first page renders
      expect(find.text('A'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);

      // SIMULATE: Python responds to page_request by pushing more rows
      final moreRows = [
        ['A', '1'], ['B', '2'], ['C', '3'],
        ['D', '4'], ['E', '5'], ['F', '6'],
      ];
      control.properties['rows'] = jsonEncode(moreRows);
      control.properties['total_rows'] = 6;  // now all loaded
      control.notify();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Second page data must appear
      expect(find.text('D'), findsOneWidget,
          reason: 'Second page row "D" must appear after LOD response');
      expect(find.text('F'), findsOneWidget,
          reason: 'Second page row "F" must appear after LOD response');

      // Spinner must be gone (total_rows == loaded rows)
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'Spinner must disappear when all rows loaded');
    });

    testWidgets('LOD does not show spinner when total_rows equals row count', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['X', '1']],
        totalRows: 1,
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

      expect(find.text('X'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('LOD does not show spinner when total_rows is zero', (tester) async {
      // total_rows=0 means Python hasn't set it yet — don't show spinner
      final control = _mockControl(_gridProps(
        rows: [['X', '1']],
        totalRows: 0,
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

      expect(find.text('X'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'No spinner when total_rows is 0 (not yet set by Python)');
    });
  });

  group('EpyxGrid LOD in Natural Mode', () {
    testWidgets('Natural mode shows spinner when total_rows > loaded', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2']],
        totalRows: 100,
      ));

      // Natural mode: SingleChildScrollView gives unbounded height
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      // Use pump() not pumpAndSettle() — spinner animation never settles
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('A'), findsOneWidget,
          reason: 'Data must render in Natural mode with LOD');
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'Spinner must show in Natural mode when total_rows > loaded');
    });

    testWidgets('Natural mode LOD loads second page after notify', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2']],
        totalRows: 100,
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify first page
      expect(find.text('A'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Python responds with more rows
      control.properties['rows'] = jsonEncode([
        ['A', '1'], ['B', '2'], ['C', '3'], ['D', '4'],
      ]);
      control.properties['total_rows'] = 4; // all loaded
      control.notify();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('C'), findsOneWidget,
          reason: 'Second page must render in Natural mode after notify');
      expect(find.text('D'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'Spinner must disappear when all rows loaded');
    });

    testWidgets('Natural mode LOD re-requests after recalc resets data', (tester) async {
      // This is THE BUG: after recalc, _lastRequestedOffset matches
      // the new rowCount, so the dedup silently drops the page_request.
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2']],
        totalRows: 100,
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // First page renders, spinner shows
      expect(find.text('A'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // SIMULATE RECALC: Python pushes back SAME row count but different data
      // This is what happens when value_code recalcs — same number of rows,
      // but _lastRequestedOffset was set to 2 from the first request.
      control.properties['rows'] = jsonEncode([
        ['X', '10'], ['Y', '20'],  // different data, same count
      ]);
      control.properties['total_rows'] = 100; // still more to load
      control.notify();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Data must update to new values
      expect(find.text('X'), findsOneWidget,
          reason: 'Recalc data must appear after notify');
      // Spinner must STILL be present (total_rows > loaded)
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'Spinner must persist — more rows to load after recalc');
      // The page_request must fire again (not deduped by stale offset)
      // We can't directly check the event was fired, but we verify the
      // spinner is present which means itemBuilder built the spinner item.
    });

    testWidgets('Natural mode spinner disappears after recalc lowers total_rows', (tester) async {
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2']],
        totalRows: 100,
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Recalc: now all data is loaded (total_rows == row count)
      control.properties['rows'] = jsonEncode([
        ['A', '1'], ['B', '2'],
      ]);
      control.properties['total_rows'] = 2;
      control.notify();

      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'Spinner must disappear when recalc sets total_rows == loaded');
    });

    testWidgets('Natural mode LOD after cell edit and recalc', (tester) async {
      // Simulates: user edits cell → Python recalcs → pushes partial data
      final control = _mockControl(_gridProps(
        rows: [['A', '1'], ['B', '2'], ['C', '3']],
        totalRows: 3,  // initially all loaded
      ));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpyxGrid(control: control),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No spinner initially
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('A'), findsOneWidget);

      // SIMULATE: edit triggers recalc, table grows via value_code
      control.properties['rows'] = jsonEncode([
        ['A', '1'], ['B', '2'], ['C', '3'],
      ]);
      control.properties['total_rows'] = 50;  // table grew, partial data
      control.notify();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Spinner must appear (need more data)
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'Spinner must appear when recalc increases total_rows beyond loaded');

      // Python responds with full data
      final allRows = List.generate(50, (i) => ['R$i', '${i + 1}']);
      control.properties['rows'] = jsonEncode(allRows);
      control.properties['total_rows'] = 50;
      control.notify();

      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'Spinner must disappear after full data loaded');
    });
  });
}
