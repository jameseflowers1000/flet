/// Buffered diagnostic logger for flet-core code.
///
/// Call sites append a string to an in-memory list (~50 ns); a
/// periodic Timer (2 s) flushes the buffer to `~/.epyx/vim_editor.log`
/// in one batched file write off the critical path.
///
/// We deliberately avoid sync `File.writeAsStringSync` at the call
/// site: a previous sync probe in `page.dart`'s keyboard handler was
/// accidentally serializing away a real focus-event race on Cmd-E
/// (the ~1 ms blocking duration was on the same scale as the race
/// we were trying to catch). List-append is ~50 ns and won't perturb
/// timing on that scale.
///
/// Shares the target file (`~/.epyx/vim_editor.log`) with
/// `flet-vim-editor`'s `log.dart` (which has its own buffer). POSIX
/// append-only writes from independent buffers are race-free, and
/// every entry carries an epoch timestamp for post-hoc ordering.
library;

import 'dart:async';
import 'dart:io' show File, FileMode, Platform, Directory;

final List<String> _buf = <String>[];
Timer? _flushTimer;

/// Append `line` to the diagnostic buffer. Cheap; safe to call from
/// hot paths. Lines are flushed to `~/.epyx/vim_editor.log` by a
/// periodic Timer every 2 seconds.
void diagLog(String line) {
  _buf.add(line);
  _flushTimer ??=
      Timer.periodic(const Duration(seconds: 2), (_) => _flush());
}

void _flush() {
  if (_buf.isEmpty) return;
  final lines = List<String>.from(_buf);
  _buf.clear();
  try {
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      final dir = Directory('$home/.epyx');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('$home/.epyx/vim_editor.log').writeAsStringSync(
          '${lines.join('\n')}\n',
          mode: FileMode.append);
    }
  } catch (_) {/* diagnostic must never crash */}
}
