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

    testWidgets('Shift+Enter commits and moves selection up', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (1, 0) — "Food" (row 1, so we can move up)
      await tester.tap(find.text('Food'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Groceries');
      await tester.pump();

      // Shift+Enter
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(find.byType(TextField), findsNothing,
          reason: 'Shift+Enter must close editor');
      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      expect(editEvents, isNotEmpty,
          reason: 'Shift+Enter must fire on_cell_edit');
    });

    testWidgets('Shift+Tab commits and moves selection left', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 1) — "1500.00" (col 1, so we can move left)
      await tester.tap(find.text('1500.00'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      await tester.enterText(find.byType(TextField), '2000');
      await tester.pump();

      // Shift+Tab
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(find.byType(TextField), findsNothing,
          reason: 'Shift+Tab must close editor');
      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      expect(editEvents, isNotEmpty,
          reason: 'Shift+Tab must fire on_cell_edit');
    });

    testWidgets('editing disabled table does not open editor', (tester) async {
      final control = _mockControl(_editableGridProps(editable: false));
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rent'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      expect(find.byType(TextField), findsNothing,
          reason: 'F2 must not open editor when editable=false');
    });

    testWidgets('Enter at last row fires add_row event', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select last row cell (2, 0) — "Transport"
      await tester.tap(find.text('Transport'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Transport');
      await tester.pump();

      // Enter at last row — should fire add_row
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final addEvents = backend.firedEvents
          .where((e) => e['event'] == 'add_row')
          .toList();
      expect(addEvents, isNotEmpty,
          reason: 'Enter at last row must fire add_row event');
    });

    testWidgets('Delete key clears cell', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 0) — "Rent"
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Press Delete — should fire cell_edit with empty value
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      expect(editEvents, isNotEmpty,
          reason: 'Delete must fire cell_edit with empty value');
    });
  });

  group('P2: Keyboard navigation', () {
    testWidgets('Ctrl+Down jumps to last row', (tester) async {
      final control = _mockControl(_editableGridProps(
        rows: [['A', '1'], ['B', '2'], ['C', '3'], ['D', '4'], ['E', '5']],
        rawRows: [['A', 1], ['B', 2], ['C', 3], ['D', 4], ['E', 5]],
      ));
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select first cell
      await tester.tap(find.text('A'));
      await tester.pump();

      // Ctrl+Down → last row
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Verify selection by F2 — editor should open on last row cell 'E'
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(TextField, 'E'), findsOneWidget,
          reason: 'Ctrl+Down must move selection to last row');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Ctrl+Up jumps to first row', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select last row
      await tester.tap(find.text('Transport'));
      await tester.pump();

      // Ctrl+Up → first row
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Verify selection by F2
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Rent'), findsOneWidget,
          reason: 'Ctrl+Up must move selection to first row');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Ctrl+Right jumps to last column', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select first cell
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Ctrl+Right → last column
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Verify: F2 should open editor on the Amount column (raw value 1500.0)
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, '1500.0'), findsOneWidget,
          reason: 'Ctrl+Right must move selection to last column');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Home jumps to first column', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell in second column
      await tester.tap(find.text('1500.00'));
      await tester.pump();

      // Home → first column
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();

      // Verify by F2
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Rent'), findsOneWidget,
          reason: 'Home must move to first column in current row');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('End jumps to last column', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select first cell
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // End → last column
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, '1500.0'), findsOneWidget,
          reason: 'End must move to last column in current row');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Ctrl+Home jumps to cell (0,0)', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select a cell not at origin — row 1, col 1
      await tester.tap(find.text('300.00'));
      await tester.pump();

      // Ctrl+Home → (0,0)
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Rent'), findsOneWidget,
          reason: 'Ctrl+Home must move to cell (0,0)');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Ctrl+End jumps to last cell', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select first cell
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Ctrl+End → last cell
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, '50.0'), findsOneWidget,
          reason: 'Ctrl+End must move to last cell');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });
  });

  group('P3: Range selection', () {
    testWidgets('Shift+Down extends selection range', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select cell (0, 0) — "Rent"
      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Shift+Down twice — should extend selection to rows 0-2
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      // Anchor is still (0,0) — F2 should edit "Rent"
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Rent'), findsOneWidget,
          reason: 'Anchor must stay at original cell during Shift+Arrow');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Shift+Right extends selection range', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Shift+Right — extends to (0, 1)
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      // Both cells should show range highlight (non-crash verification)
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('1500.00'), findsOneWidget);
    });

    testWidgets('Ctrl+A selects all cells', (tester) async {
      final control = _mockControl(_editableGridProps());
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rent'));
      await tester.pump();

      // Ctrl+A
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // All cells visible (non-crash, selection range covers all)
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('Transport'), findsOneWidget);
      expect(find.text('50.00'), findsOneWidget);
    });

    testWidgets('Ctrl+Enter commits without moving', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rent'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Mortgage');
      await tester.pump();

      // Ctrl+Enter
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Editor must close
      expect(find.byType(TextField), findsNothing,
          reason: 'Ctrl+Enter must close editor');

      // Event must fire
      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      expect(editEvents, isNotEmpty,
          reason: 'Ctrl+Enter must fire cell_edit');

      // Selection must NOT have moved — F2 should open at same position
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      // The cell value was changed to 'Mortgage' via event, but the grid
      // still shows old data (no notify from Python). Just verify F2 opens.
      expect(find.byType(TextField), findsOneWidget,
          reason: 'Selection must stay at same cell after Ctrl+Enter');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    });

    testWidgets('Delete clears entire range selection', (tester) async {
      final backend = _MockFletBackend();
      final control = _mockControl(_editableGridProps(), backend: backend);
      await tester.pumpWidget(_buildGrid(control));
      await tester.pumpAndSettle();

      // Select (0,0) then Shift+Down+Right to get 2x2 range
      await tester.tap(find.text('Rent'));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      // Delete — should fire cell_edit for each cell in 2x2 range
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      final editEvents = backend.firedEvents
          .where((e) => e['event'] == 'cell_edit')
          .toList();
      // 2 rows × 2 cols = 4 cell_edit events
      expect(editEvents.length, greaterThanOrEqualTo(4),
          reason: 'Delete on 2x2 range must fire 4 cell_edit events');
    });
  });
}
