// P2 Cell Editing Tests — written BEFORE implementation.
// Every test here MUST FAIL until the corresponding feature is built.
// Test-first: define behavior, then implement until green.
//
// Reference: SUPERTAB_WIDGET.md §7 Phase 2, §4.3, §4.12

import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flet_supertab/src/epyx_grid.dart';

// ── Mock helpers (same as widget test) ──────────────────────────

class _MockFletBackend implements FletBackend {
  final List<Map<String, dynamic>> firedEvents = [];

  @override
  void triggerControlEventById(int id, String eventName, [dynamic data]) {
    firedEvents.add({'event': eventName, 'data': data});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Control _mockControl(Map<String, dynamic> props, {_MockFletBackend? backend}) {
  final b = backend ?? _MockFletBackend();
  return Control(
    id: 1,
    type: 'flet_supertab',
    properties: props,
    backend: b,
  );
}

Map<String, dynamic> _editableGridProps({
  List<Map<String, dynamic>>? columns,
  List<List<dynamic>>? rows,
  List<List<dynamic>>? rawRows,
  bool editable = true,
}) {
  final cols = columns ?? [
    {'name': 'item', 'label': 'Item', 'dtype': 'str', 'format': '', 'read_only': false, 'alignment': 'centerLeft'},
    {'name': 'amount', 'label': 'Amount', 'dtype': 'float', 'format': '', 'read_only': false, 'alignment': 'centerRight'},
  ];
  final data = rows ?? [
    ['Rent', '1500.00'],
    ['Food', '300.00'],
    ['Transport', '50.00'],
  ];
  final raw = rawRows ?? [
    ['Rent', 1500.0],
    ['Food', 300.0],
    ['Transport', 50.0],
  ];

  return {
    'columns': jsonEncode(cols),
    'rows': jsonEncode(data),
    'raw_rows': jsonEncode(raw),
    'total_rows': data.length,
    'editable': editable,
    'label': 'Test',
    'ctype': 'comparison',
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

Widget _buildGrid(Control control) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: EpyxGrid(control: control),
      ),
    ),
  );
}

void main() {
  group('P2: Cell editing overlay', () {
    testWidgets('F2 opens edit overlay on selected cell', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 0) — "Rent"
      expect(find.text('Rent'), findsOneWidget);
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Press F2 to edit
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      // A TextField overlay must appear with the raw value
      expect(find.byType(TextField), findsOneWidget,
          reason: 'F2 must open a TextField overlay for editing');
    });

    testWidgets('Escape cancels editing without changing data', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select and edit
      await tester.tap(find.text('Rent'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      // Type something
      await tester.enterText(find.byType(TextField), 'Mortgage');
      await tester.pump();

      // Escape — must cancel
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // TextField must be gone
      expect(find.byType(TextField), findsNothing,
          reason: 'Escape must close the edit overlay');
      // Original value must remain
      expect(find.text('Rent'), findsOneWidget,
          reason: 'Escape must not change the cell value');
    });

    testWidgets('Enter commits edit and moves selection down', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 0) and edit
      await tester.tap(find.text('Rent'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      // Type new value
      await tester.enterText(find.byType(TextField), 'Mortgage');
      await tester.pump();

      // Enter — commit + move down
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      // TextField must be gone
      expect(find.byType(TextField), findsNothing,
          reason: 'Enter must close the edit overlay');

      // on_cell_edit event must have fired
      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      expect(editEvents, isNotEmpty,
          reason: 'Enter must fire on_cell_edit event to Python');
    });

    testWidgets('Tab commits and moves selection right', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 0) and edit
      await tester.tap(find.text('Rent'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Mortgage');
      await tester.pump();

      // Tab — commit + move right
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(find.byType(TextField), findsNothing,
          reason: 'Tab must close the edit overlay');

      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      expect(editEvents, isNotEmpty,
          reason: 'Tab must fire on_cell_edit event');
    });

    testWidgets('Type-to-replace starts editing with typed character', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 0)
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Type 'M' without pressing F2 first — should start editing
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget,
          reason: 'Typing a character must start editing (type-to-replace)');
    });

    testWidgets('Read-only column blocks editing', (tester) async {
      final control = _mockControl(_editableGridProps(
        columns: [
          {'name': 'item', 'label': 'Item', 'dtype': 'str', 'format': '', 'read_only': true, 'alignment': 'centerLeft'},
          {'name': 'amount', 'label': 'Amount', 'dtype': 'float', 'format': '', 'read_only': false, 'alignment': 'centerRight'},
        ],
      ));
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select read-only cell (0, 0)
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // F2 — should NOT open editor on read-only column
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      expect(find.byType(TextField), findsNothing,
          reason: 'F2 must not open editor on read-only column');
    });

    testWidgets('= key opens code editor (multi-line TextField)', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Press = key
      await tester.sendKeyDownEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
      await tester.pump();

      // A TextField must appear (code mode may be multi-line)
      expect(find.byType(TextField), findsOneWidget,
          reason: '= key must open code editor overlay');
    });
  });
}
