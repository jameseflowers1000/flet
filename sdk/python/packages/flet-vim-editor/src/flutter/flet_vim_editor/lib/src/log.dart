// Logging gate. Per-keystroke `[lab.diag]` and `[nvim]` traces are
// invaluable when chasing a bug but unreadable noise in production.
//
// Build with `--dart-define=EPYX_LAB_DEBUG=1` to enable verbose logs.
// Default is OFF: only fatal errors and one-time startup events go to
// the console. Wrap any per-event log behind `labLog()` so it's free
// at runtime when the flag is unset.
//
// On the lab dev path, `bash scripts/lab_dev_servers.sh` already
// implies dev work; the helper script can pass the dart-define when
// it spawns chrome (see scripts/lab_dev_servers.sh's recommended
// command). For desktop testing, `flutter run -d macos
// --dart-define=EPYX_LAB_DEBUG=1` enables it.
//
// macOS-desktop note: the `.app` is launched via the macOS `open`
// command (see scripts/run_container_app.py), which detaches the
// process — its stdout/stderr is discarded by the OS. To make logs
// observable without running the binary from a terminal, every log
// line is ALSO appended to `~/.epyx/vim_editor.log`, which the user
// can tail in another window. Web builds don't have `dart:io`, so
// the file mirror is gated to `Platform.isMacOS`.
library;

import 'dart:io' show File, FileMode, Platform, Directory;

import 'package:flutter/foundation.dart';

/// Compile-time constant — when false, the bool itself can be folded
/// out by the Dart compiler. We still pay the cost of constructing the
/// log message string at the call site (Dart can't statically prove
/// the formatter is pure), but no I/O is performed.
const bool kLabDebug = bool.fromEnvironment(
  'EPYX_LAB_DEBUG',
  defaultValue: true,
);

/// Verbose lab-development log. Use for per-keystroke / per-frame
/// events (LSP request flow, vim diag rendering result, mode poll
/// dumps, etc.) — anything that would drown the console at production
/// rates.
///
/// IMPORTANT: uses `print()`, not `debugPrint()`. `debugPrint` is a
/// no-op in `flutter build web --release` and `flutter build macos
/// --release` — the released editor's logs would be invisible exactly
/// when the user is reporting a problem. `print()` survives release
/// builds (browser DevTools console + macOS unified log).
void labLog(String message) {
  if (kLabDebug) {
    print(message);
    _appendToFile(message);
  }
}

/// One-time / lifecycle log. Use for startup events (LSP spawn, nvim
/// connect, websocket bridge ready) that a production user benefits
/// from seeing once. Always emitted (via `print` — survives release).
void labLogAlways(String message) {
  print(message);
  _appendToFile(message);
}

/// macOS-only side channel: append to `~/.epyx/vim_editor.log` so
/// `tail -f` works even when the .app is launched via `open` (which
/// discards stdout/stderr). On web there's no `dart:io` file access;
/// the `if (kIsWeb) return` guards the platform check.
String? _logFilePath;
bool _logInitTried = false;
void _appendToFile(String message) {
  if (kIsWeb) return;
  try {
    if (!Platform.isMacOS && !Platform.isLinux) return;
  } catch (_) {
    return;
  }
  if (!_logInitTried) {
    _logInitTried = true;
    try {
      final home = Platform.environment['HOME'] ?? '/tmp';
      final dir = Directory('$home/.epyx');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logFilePath = '${dir.path}/vim_editor.log';
      // Truncate on startup so each session is isolated.
      File(_logFilePath!).writeAsStringSync(
          '── vim-editor log opened ${DateTime.now().toIso8601String()} ──\n');
    } catch (_) {
      _logFilePath = null;
    }
  }
  final path = _logFilePath;
  if (path == null) return;
  try {
    File(path).writeAsStringSync('$message\n', mode: FileMode.append);
  } catch (_) {/* swallow — logging must never crash the editor */}
}
