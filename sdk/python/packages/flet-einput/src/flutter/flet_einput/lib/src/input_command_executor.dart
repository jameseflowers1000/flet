import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// State the executor manipulates. The hosting widget passes a snapshot
/// of these handles + callbacks; the executor mutates the controller and
/// invokes the callbacks for non-text actions (commit, banner, focus moves).
class InputCommandTarget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String reason) onCommit;
  final VoidCallback onCancel;
  final void Function(String message, String level) onBanner;

  InputCommandTarget({
    required this.controller,
    required this.focusNode,
    required this.onCommit,
    required this.onCancel,
    required this.onBanner,
  });
}

/// Executes a command list returned by `def on_key()` in user spec_code.
///
/// Each command is a Map with a `cmd` key. Unknown commands are silently
/// skipped (forward-compatible — user code can use commands the Dart side
/// doesn't yet implement, and they become no-ops).
///
/// Returns true if at least one command was executed (and the key event
/// should be considered handled).
class InputCommandExecutor {
  static bool execute(List<dynamic> commands, InputCommandTarget target) {
    if (commands.isEmpty) return false;
    bool any = false;
    for (final cmd in commands) {
      if (cmd is! Map) continue;
      final name = cmd['cmd'] as String? ?? '';
      switch (name) {
        case 'commit':
          target.onCommit('command');
          // Belt-and-suspenders: schedule a post-frame focus restore in
          // case some path (Flutter EditableText, browser native text
          // input, Python push) drops focus before the next frame. The
          // re-request is a no-op when focus is already on the node.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (target.focusNode.canRequestFocus &&
                !target.focusNode.hasFocus) {
              target.focusNode.requestFocus();
            }
          });
          any = true;
          break;

        case 'cancel':
          target.onCancel();
          any = true;
          break;

        case 'replace':
          // Replace entire content with `text`.
          final text = (cmd['text'] as Object?)?.toString() ?? '';
          target.controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
          any = true;
          break;

        case 'insert':
          // Insert at cursor (or replace selection if any).
          final text = (cmd['text'] as Object?)?.toString() ?? '';
          final selection = target.controller.selection;
          final current = target.controller.text;
          final start = selection.start.clamp(0, current.length);
          final end = selection.end.clamp(0, current.length);
          final newText =
              current.substring(0, start) + text + current.substring(end);
          target.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: start + text.length),
          );
          any = true;
          break;

        case 'select_all':
          target.controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: target.controller.text.length,
          );
          // Re-apply on the next frame so that anything which lands
          // between now and the next paint (e.g. a Python display update,
          // a focus restoration) doesn't reset the selection.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!target.focusNode.hasFocus) {
              target.focusNode.requestFocus();
            }
            target.controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: target.controller.text.length,
            );
          });
          any = true;
          break;

        case 'select':
          final start = (cmd['start'] as num?)?.toInt() ?? 0;
          final end = (cmd['end'] as num?)?.toInt() ?? start;
          final len = target.controller.text.length;
          target.controller.selection = TextSelection(
            baseOffset: start.clamp(0, len),
            extentOffset: end.clamp(0, len),
          );
          any = true;
          break;

        case 'move_cursor':
          // `to` accepts int, "start", or "end"
          final to = cmd['to'];
          int offset;
          if (to == 'start') {
            offset = 0;
          } else if (to == 'end') {
            offset = target.controller.text.length;
          } else if (to is num) {
            offset = to.toInt().clamp(0, target.controller.text.length);
          } else {
            break;
          }
          target.controller.selection = TextSelection.collapsed(offset: offset);
          any = true;
          break;

        case 'delete_selection':
          final selection = target.controller.selection;
          if (!selection.isValid || selection.isCollapsed) break;
          final current = target.controller.text;
          final start = selection.start.clamp(0, current.length);
          final end = selection.end.clamp(0, current.length);
          final newText = current.substring(0, start) + current.substring(end);
          target.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: start),
          );
          any = true;
          break;

        case 'clear':
          target.controller.value = const TextEditingValue(
            text: '',
            selection: TextSelection.collapsed(offset: 0),
          );
          any = true;
          break;

        case 'move_to_next':
          target.focusNode.nextFocus();
          any = true;
          break;

        case 'move_to_prev':
          target.focusNode.previousFocus();
          any = true;
          break;

        case 'beep':
          // Absorbs the key, no action.
          SystemSound.play(SystemSoundType.alert);
          any = true;
          break;

        case 'banner':
          final message = (cmd['message'] as Object?)?.toString() ?? '';
          final level = (cmd['level'] as Object?)?.toString() ?? 'info';
          target.onBanner(message, level);
          any = true;
          break;
      }
    }
    return any;
  }
}
