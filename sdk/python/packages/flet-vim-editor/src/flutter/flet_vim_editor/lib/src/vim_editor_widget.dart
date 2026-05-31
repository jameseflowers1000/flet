// Flet wrapper that hosts the lab's UnifiedEditor inside a Flet
// LayoutControl. Reads `initial_text` / `uri` / `lsp_ws_url` /
// `nvim_ws_url` / `initial_mode` / `debug` from the control props,
// stands up an LspClient + NvimManager singleton based on those
// URLs, and forwards `EditSession.save()` calls back to Python via
// `triggerEvent('save', {text: ...})`.

import 'dart:async';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

import 'edit_session.dart';
import 'editor_chrome.dart' show EditorMode;
import 'editor_widget.dart' as ed;
import 'log.dart';
import 'lsp_client.dart';
import 'nvim_manager.dart';

class VimEditorFletWidget extends StatefulWidget {
  final Control control;
  const VimEditorFletWidget({super.key, required this.control});

  @override
  State<VimEditorFletWidget> createState() => _VimEditorFletWidgetState();
}

class _VimEditorFletWidgetState extends State<VimEditorFletWidget> {
  EditSession? _session;
  LspClient? _lsp;
  NvimManager? _nvim;
  String? _readyLsp;
  String? _readyNvim;
  int _lspAttempt = 0;
  int _nvimAttempt = 0;
  bool _lspConnecting = false;
  // ETB-19: counter mirroring `VimEditor.pending_insert_seq` from
  // Python. Bumps when the orchestrator wants us to insert a cell
  // reference at the cursor; didUpdateWidget detects the bump and
  // routes the text to the active backend (nvim_put for vim mode,
  // session text append for EZ mode in v1).
  int _lastInsertSeq = 0;

  // ETB-09b followup #12 — share a single LspClient across ALL VimEditor
  // instances on the same lsp_ws_url. Previously each instance created
  // its own → the LSP server's last-connection-wins eviction (see
  // server.py _start_ws_resilient) churned through clients on every
  // popup mount. The retry backoff stacked into >3s of perceived
  // downtime, which the chrome's health-banner grace caught and
  // flashed "LSP DOWN — (no detail)" briefly. With a shared healthy
  // client the popup just reuses it and the banner never fires.
  static LspClient? _sharedLsp;
  static String? _sharedLspUrl;
  static Future<LspClient>? _sharedLspStarting;
  bool _nvimConnecting = false;

  // [wmtime] build counter — marks when the editor frame is (re)built.
  int _buildCount = 0;

  @override
  void initState() {
    super.initState();
    labLogAlways('[wmtime] VimEditor.initState '
        't=${DateTime.now().millisecondsSinceEpoch}');
    _initSession();
    _maybeStartLsp();
    _maybeStartNvim();
  }

  void _initSession() {
    final initial = widget.control.getString('initial_text') ?? '';
    final label = widget.control.getString('label') ?? '';
    final uri = widget.control.getString('uri') ?? '';
    labLogAlways('[vim_editor] _initSession: initial.length=${initial.length} '
        'label="$label" uri="$uri" '
        'preview="${initial.length > 40 ? "${initial.substring(0, 40)}..." : initial}"');
    _session = EditSession(
      label: label,
      controlName: '',
      attribute: 'code',
      // Pre-built URI from Python side — pass-through. EditSession
      // would normally construct one from controlName/attribute, but
      // here Python already knows what URI the LSP expects.
      lspUriOverride: uri.isEmpty ? null : uri,
      initialText: initial,
      onSave: (text) async {
        // Use `triggerEventWithoutSubscribers` (NOT `triggerEvent`).
        // `triggerEvent` gates on `control.get("on_save") == true`, which
        // requires the host to have flagged the handler in the *initial*
        // serialization of the control to Dart. For extension
        // LayoutControls in the orchestrator's late-mounted side panel
        // that gate has been observed to fire-and-do-nothing — the
        // user clicks save, Dart drops the event silently, no Python
        // handler runs, no apply, no message. Bypassing the gate makes
        // the event always reach Python; the Python `_trigger_event`
        // re-checks `hasattr(self, 'on_<name>')` itself, so the worst
        // case (handler not yet attached on Python side) is a no-op
        // there, not a permanent black hole.
        //
        // Also: pass the full buffer as a BARE STRING, not a dict.
        // Flet's `_trigger_event` routes dict payloads through
        // `from_dict(event_type, ...)` which discards keys not declared
        // on the event class — `{'text': text}` against
        // `Event[VimEditor]` lands as `e.data = None`, and an empty
        // string overwrote the control's `code` attr. Bare-string
        // payloads short-circuit that branch.
        print('[vim_editor] save: sending text len=${text.length} '
            'control.id=${widget.control.id}');
        widget.control.triggerEventWithoutSubscribers('save', text);
        return true;
      },
    );
  }

  Future<void> _maybeStartLsp() async {
    final url = widget.control.getString('lsp_ws_url');
    if (url == null || url.isEmpty) return;

    // ETB-09b followup #12 — reuse the static shared client if it's on
    // this URL and healthy. Subsequent VimEditor mounts (e.g. opening
    // a cell popup after the side panel) skip the connect+initialize
    // round-trip entirely, which is what was producing "LSP DOWN".
    if (_VimEditorFletWidgetState._sharedLspUrl == url
        && _VimEditorFletWidgetState._sharedLsp != null
        && _VimEditorFletWidgetState._sharedLsp!.isHealthy) {
      if (_lsp != _VimEditorFletWidgetState._sharedLsp) {
        if (mounted) setState(() {
          _lsp = _VimEditorFletWidgetState._sharedLsp;
          _readyLsp = url;
        });
      }
      return;
    }
    // If another VimEditor is mid-start for this URL, wait on it.
    if (_VimEditorFletWidgetState._sharedLspStarting != null
        && _VimEditorFletWidgetState._sharedLspUrl == url) {
      try {
        final c = await _VimEditorFletWidgetState._sharedLspStarting!;
        if (!mounted) return;
        setState(() {
          _lsp = c;
          _readyLsp = url;
        });
      } catch (_) {
        // The other start failed — fall through to retry below.
      }
      return;
    }

    // Skip only when we already have a HEALTHY client on this URL.
    // Without the health check, a previous LspClient that died (WS
    // dropped, container restarted, transient network blip) sticks
    // around as a zombie — `widget.lsp != null` masks the failure and
    // the "LSP DOWN" banner persists forever because the retry loop
    // short-circuits on null-check alone. Re-running the connect path
    // when the existing client isn't healthy gives us auto-recovery.
    if (_readyLsp == url && _lsp != null && _lsp!.isHealthy) return;
    if (_lspConnecting) return;
    // Tear down a stale client before reconnecting so we don't leak
    // its stream subscription / WebSocket. `stop()` is best-effort.
    if (_lsp != null && !_lsp!.isHealthy) {
      try {
        await _lsp!.stop();
      } catch (_) {}
      if (mounted) setState(() => _lsp = null);
    }
    _lspConnecting = true;
    _readyLsp = url;
    // Publish the in-flight start so concurrent mounts can await it.
    final startCompleter = Completer<LspClient>();
    _VimEditorFletWidgetState._sharedLspUrl = url;
    _VimEditorFletWidgetState._sharedLspStarting = startCompleter.future;
    try {
      while (mounted) {
        final c = LspClient.webSocket(url: url);
        try {
          labLogAlways('[wmtime] _maybeStartLsp start() START '
              't=${DateTime.now().millisecondsSinceEpoch} url=$url');
          await c.start();
          labLogAlways('[wmtime] _maybeStartLsp start() OK '
              't=${DateTime.now().millisecondsSinceEpoch}');
          if (!mounted) {
            startCompleter.complete(c);
            _VimEditorFletWidgetState._sharedLsp = c;
            _VimEditorFletWidgetState._sharedLspStarting = null;
            return;
          }
          setState(() => _lsp = c);
          _VimEditorFletWidgetState._sharedLsp = c;
          _VimEditorFletWidgetState._sharedLspStarting = null;
          startCompleter.complete(c);
          return;
        } catch (e) {
          _lspAttempt += 1;
          labLogAlways('[wmtime] LSP start FAILED (attempt $_lspAttempt) '
              't=${DateTime.now().millisecondsSinceEpoch}: $e');
          // Pygls inside the container takes a beat to come up after a
          // container restart. Retry with simple back-off (clamped) so
          // a transient race resolves without the user touching anything.
          final delayMs = (300 * (_lspAttempt < 6 ? _lspAttempt : 6))
              .clamp(300, 3000);
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    } finally {
      _lspConnecting = false;
    }
  }

  Future<void> _maybeStartNvim() async {
    final url = widget.control.getString('nvim_ws_url');
    if (url == null || url.isEmpty) return;
    // Same health-aware reconnect logic as the LSP path — null-only
    // check leaves a dead nvim manager pinned and the editor unusable.
    if (_readyNvim == url && _nvim != null && (_nvim!.isHealthy)) return;
    if (_nvimConnecting) return;
    if (_nvim != null && !_nvim!.isHealthy) {
      if (mounted) setState(() => _nvim = null);
    }
    _nvimConnecting = true;
    _readyNvim = url;
    try {
      while (mounted) {
        try {
          labLogAlways('[wmtime] _maybeStartNvim connectExisting START '
              't=${DateTime.now().millisecondsSinceEpoch} url=$url');
          final mgr = await NvimManager.connectExisting(nvimWsUrl: url);
          labLogAlways('[wmtime] _maybeStartNvim connectExisting OK '
              't=${DateTime.now().millisecondsSinceEpoch}');
          if (!mounted) return;
          setState(() => _nvim = mgr);
          return;
        } catch (e) {
          _nvimAttempt += 1;
          labLogAlways('[wmtime] nvim connect FAILED (attempt $_nvimAttempt) '
              't=${DateTime.now().millisecondsSinceEpoch}: $e');
          final delayMs = (300 * (_nvimAttempt < 6 ? _nvimAttempt : 6))
              .clamp(300, 3000);
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    } finally {
      _nvimConnecting = false;
    }
  }

  @override
  void didUpdateWidget(covariant VimEditorFletWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the control props changed (orchestrator built a new VimEditor
    // with a different `uri` / `initial_text` for a different /edit
    // target), rebuild the session so the editor reflects the new
    // content. Without this, when Flet recycles the State across a
    // control-prop diff the editor would keep the original session
    // (and the user would see the prior control's code).
    // Compare new prop values against OLD prop values, NOT the live
    // session. The live session reflects the user's in-progress edits;
    // after save, Python's prop._code advances but the Flet control's
    // `initial_text` prop is NOT re-pushed to Dart (it still holds the
    // value from the original /edit call). If we compared against
    // _session.text, any unrelated didUpdateWidget tick would detect
    // "newInitial != session.text" and revert the editor to the stale
    // prop value. Diff against oldWidget's prop so we only re-init
    // when Python actually pushes a *new* initial_text.
    final newUri = widget.control.getString('uri') ?? '';
    final newInitial = widget.control.getString('initial_text') ?? '';
    final oldUri = oldWidget.control.getString('uri') ?? '';
    final oldInitial = oldWidget.control.getString('initial_text') ?? '';
    if (newUri != oldUri || newInitial != oldInitial) {
      print('[vim_editor] didUpdateWidget: prop change — '
          'oldUri="$oldUri" newUri="$newUri" '
          'oldLen=${oldInitial.length} newLen=${newInitial.length} — '
          're-initializing session');
      _initSession();
      // setState so the build() below picks up the new _session.
      setState(() {});
    }
    _maybeStartLsp();
    _maybeStartNvim();
    // ETB-19: insert-at-cursor request from Python. The Python side
    // calls `editor.insert_at_cursor(text)` which bumps
    // `pending_insert_seq` and stuffs the text in `pending_insert_text`.
    // We mirror the seq locally and dispatch when it moves forward.
    final newSeq = widget.control.getInt("pending_insert_seq", 0) ?? 0;
    if (newSeq > _lastInsertSeq) {
      _lastInsertSeq = newSeq;
      final text = widget.control.getString("pending_insert_text") ?? '';
      if (text.isNotEmpty) {
        _handleInsertAtCursor(text);
      }
    }
  }

  /// ETB-19: insert `text` at the editor's current cursor. Vim mode →
  /// `nvim_put` (mode-agnostic, single undo step); EZ mode (v1) → append
  /// to session text. Same API surface from Python regardless of mode.
  void _handleInsertAtCursor(String text) {
    final rpc = _nvim?.rpc;
    if (rpc != null) {
      // 'c' = char-mode; after=false = insert AT cursor; follow=true =
      // move cursor to the end of the inserted text. Works whether the
      // user is in normal or insert mode.
      rpc.request('nvim_put', [[text], 'c', false, true]).catchError((e) {
        print('[etb19] nvim_put failed: $e');
      });
      return;
    }
    // EZ-mode fallback v1: append at the end. Cursor-position insertion
    // for EZ is a quick follow-up (TextEditingController.selection).
    if (_session != null) {
      _session!.setText(_session!.text + text);
    }
  }

  @override
  void dispose() {
    // ETB-09b followup #12 — LSP client is now ALSO process-global
    // (singleton, shared across VimEditor instances) to avoid the
    // connect/evict/retry churn that produced "LSP DOWN" banners.
    // Only stop the client if it's NOT the shared one (e.g. a stale
    // instance from a URL-change before we adopted the singleton).
    if (_lsp != null && _lsp != _VimEditorFletWidgetState._sharedLsp) {
      _lsp!.stop();
    }
    // NvimManager is process-global (singleton); don't dispose it here.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) return const SizedBox.shrink();
    labLogAlways('[wmtime] VimEditorFletWidget.build #${++_buildCount} '
        't=${DateTime.now().millisecondsSinceEpoch} '
        'lsp=${_lsp != null} nvim=${_nvim != null}');
    final modeStr = widget.control.getString('initial_mode') ?? 'native';
    final mode = modeStr == 'nvim'
        ? EditorMode.nvim
        : EditorMode.native;
    return ed.UnifiedEditor(
      session: _session!,
      lsp: _lsp,
      nvim: _nvim,
      initialMode: mode,
      autofocus: widget.control.getBool('autofocus', false) ?? false,
      onCancel: () {
        // Same rationale as save: bypass the on_$event flag gate.
        widget.control.triggerEventWithoutSubscribers('cancel', null);
      },
      onModeChange: (modeStr) {
        // Forward mode toggles to Python so the orchestrator can
        // persist the preference (next `/edit` reopens in the same
        // mode). Bare-string payload — same reason as `save`.
        widget.control.triggerEventWithoutSubscribers('mode_change', modeStr);
      },
    );
  }
}
