// EpyxGrid Test Bridge API
// Handles test commands sent from Python via Flet control events.
// Gated by EPYX_TEST_MODE environment variable.
//
// Protocol: Python sends JSON command → Dart processes → Dart sets
// result property on the control → Python reads it back.
//
// Reference: SUPERTAB_WIDGET.md §5 (Test Bridge Protocol)

import 'dart:convert';

import 'package:flet/flet.dart';

/// Test API handler for EpyxGrid.
///
/// Processes commands like get_cell_text, get_selection, tap_cell, etc.
/// and sends results back via the control's property update mechanism.
class EpyxGridTestApi {
  final Control control;

  // Callbacks into the grid widget state
  final String Function(int row, int col) getCellText;
  final Map<String, int> Function() getSelection;
  final Map<String, int> Function() getSelectionRange;
  final double Function(int col) getColumnWidth;
  final bool Function() getIsEditing;
  final int Function() getVisibleRowCount;
  final int Function() getFirstVisibleRow;
  final void Function(int row, int col) simulateTap;
  final void Function(String key, Set<String> modifiers) simulateKey;

  EpyxGridTestApi({
    required this.control,
    required this.getCellText,
    required this.getSelection,
    required this.getSelectionRange,
    required this.getColumnWidth,
    required this.getIsEditing,
    required this.getVisibleRowCount,
    required this.getFirstVisibleRow,
    required this.simulateTap,
    required this.simulateKey,
  });

  /// Check if test mode is enabled.
  static bool get isTestMode {
    return const bool.fromEnvironment('EPYX_TEST_MODE', defaultValue: false) ||
        const String.fromEnvironment('EPYX_TEST_MODE') == 'true';
  }

  /// Handle a test command. Returns the JSON result string.
  String handleCommand(String commandJson) {
    try {
      final cmd = jsonDecode(commandJson) as Map<String, dynamic>;
      final action = cmd['action'] as String;

      switch (action) {
        case 'get_cell_text':
          final row = cmd['row'] as int;
          final col = cmd['col'];
          // col can be int (index) or string (column name)
          final colIndex = col is int ? col : -1;
          final text = getCellText(row, colIndex);
          return jsonEncode({'result': text});

        case 'get_selection':
          final sel = getSelection();
          return jsonEncode({'result': sel});

        case 'get_selection_range':
          final range = getSelectionRange();
          return jsonEncode({'result': range});

        case 'get_column_width':
          final col = cmd['col'] as int;
          final width = getColumnWidth(col);
          return jsonEncode({'result': width});

        case 'is_editing':
          return jsonEncode({'result': getIsEditing()});

        case 'visible_row_count':
          return jsonEncode({'result': getVisibleRowCount()});

        case 'first_visible_row':
          return jsonEncode({'result': getFirstVisibleRow()});

        case 'tap_cell':
          final row = cmd['row'] as int;
          final col = cmd['col'] as int;
          simulateTap(row, col);
          return jsonEncode({'result': 'ok'});

        case 'send_key':
          final key = cmd['key'] as String;
          final mods = (cmd['modifiers'] as List?)
                  ?.map((m) => m.toString())
                  .toSet() ??
              {};
          simulateKey(key, mods);
          return jsonEncode({'result': 'ok'});

        default:
          return jsonEncode({'error': 'Unknown action: $action'});
      }
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }
}
