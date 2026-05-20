// Buffered diagnostic logging.
//
// Log call sites append a line to an in-memory list (~50 nanoseconds);
// a periodic Timer flushes the buffer to `~/.epyx/vim_editor.log` every
// few seconds (one batched file write, off the critical path).
//
// Why this matters here, and why we don't use sync file I/O at the
// call site: today (2026-05-20) we discovered that a sync
// `File.writeAsStringSync` in `page.dart`'s keyboard-event handler was
// accidentally serializing away two real focus-event races (blue
// outline disappearing on Cmd-E; first nvim click not transferring
// keyboard focus). Sync I/O at the call site doesn't just *measure*
// timing-sensitive code — it changes the system's behaviour, because
// the ~1ms blocking duration is on the same order as the races we're
// trying to catch. Append-to-list is ~50ns and won't perturb anything
// on that scale. See feedback_python_dash_m_two_modules.md and the
// session log for the discovery.
//
// macOS-desktop note: the `.app` is launched via the macOS `open`
// command (see scripts/run_container_app.py), which detaches the
// process — its stdout/stderr is discarded by the OS. To make logs
// observable without running the binary from a terminal, every log
// line is appended to `~/.epyx/vim_editor.log`, which the user can
// tail in another window. Web builds don't have `dart:io`, so the
// file mirror is gated to `Platform.isMacOS` / `Linux`.
library;

import 'dart:async';
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

// In-memory buffer. Writes are cheap appends; flushed periodically.
final List<String> _buf = <String>[];
Timer? _flushTimer;
String? _logFilePath;
bool _initTried = false;

/// Flush cadence. 2s is fast enough to read fresh data during a debug
/// session, slow enough that file I/O cost is negligible.
const Duration _flushInterval = Duration(seconds: 2);

void _ensureInit() {
  if (_initTried) return;
  _initTried = true;
  if (kIsWeb) return;
  try {
    if (!Platform.isMacOS && !Platform.isLinux) return;
  } catch (_) {
    return;
  }
  try {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final dir = Directory('$home/.epyx');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _logFilePath = '${dir.path}/vim_editor.log';
    // APPEND a session marker — do NOT truncate. This file is shared
    // with page.dart's `diag_log` (in flet-core), which writes events
    // BEFORE the editor mounts: page-keydown timestamps for Cmd-E,
    // EpyxFocusable focus transitions while the user is clicking around
    // the doclet, etc. Truncating here erased exactly the pre-mount
    // events we need to diagnose bug 1 (markdown outline disappearing
    // on Cmd-E). The file grows across sessions; user can rm it when
    // they want a clean slate.
    File(_logFilePath!).writeAsStringSync(
        '\n── vim-editor log opened ${DateTime.now().toIso8601String()} ──\n',
        mode: FileMode.append);
    _flushTimer = Timer.periodic(_flushInterval, (_) => _flush());
  } catch (_) {
    _logFilePath = null;
  }
}

void _flush() {
  if (_buf.isEmpty) return;
  final path = _logFilePath;
  if (path == null) return;
  // Snapshot then write. New appends during the write end up in the
  // next batch — they don't get lost.
  final lines = List<String>.from(_buf);
  _buf.clear();
  try {
    File(path).writeAsStringSync(
        '${lines.join('\n')}\n', mode: FileMode.append);
  } catch (_) {/* swallow — logging must never crash the editor */}
}

/// Verbose lab-development log. Use for per-keystroke / per-frame
/// events. Off when `EPYX_LAB_DEBUG=0` is passed at build time.
void labLog(String message) {
  if (!kLabDebug) return;
  _ensureInit();
  _buf.add(message);
}

/// One-time / lifecycle log. Always emitted regardless of `kLabDebug`.
void labLogAlways(String message) {
  _ensureInit();
  _buf.add(message);
}

/// Force a buffer flush immediately. Useful from a one-shot diagnostic
/// hook (`window._epyxVimDiag()` etc.) where the caller wants to see
/// the data NOW without waiting for the periodic timer.
void labLogFlush() {
  _flush();
}
