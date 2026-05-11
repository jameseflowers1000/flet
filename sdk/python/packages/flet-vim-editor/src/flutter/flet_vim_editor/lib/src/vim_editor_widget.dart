// Flet wrapper that hosts the lab's UnifiedEditor inside a Flet
// LayoutControl. Reads `initial_text` / `uri` / `lsp_ws_url` /
// `nvim_ws_url` / `initial_mode` / `debug` from the control props,
// stands up an LspClient + NvimManager singleton based on those
// URLs, and forwards `EditSession.save()` calls back to Python via
// `triggerEvent('save', {text: ...})`.

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

import 'edit_session.dart';
import 'editor_chrome.dart' show EditorMode;
import 'editor_widget.dart' as ed;
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
  bool _nvimConnecting = false;

  @override
  void initState() {
    super.initState();
    _initSession();
    _maybeStartLsp();
    _maybeStartNvim();
  }

  void _initSession() {
    final initial = widget.control.getString('initial_text') ?? '';
    final label = widget.control.getString('label') ?? '';
    final uri = widget.control.getString('uri') ?? '';
    print('[vim_editor] _initSession: initial.length=${initial.length} '
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
    if (_readyLsp == url && _lsp != null) return;
    if (_lspConnecting) return;
    _lspConnecting = true;
    _readyLsp = url;
    try {
      while (mounted) {
        final c = LspClient.webSocket(url: url);
        try {
          await c.start();
          if (!mounted) return;
          setState(() => _lsp = c);
          return;
        } catch (e) {
          _lspAttempt += 1;
          debugPrint('[vim_editor] LSP start failed (attempt $_lspAttempt): $e');
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
    if (_readyNvim == url && _nvim != null) return;
    if (_nvimConnecting) return;
    _nvimConnecting = true;
    _readyNvim = url;
    try {
      while (mounted) {
        try {
          final mgr = await NvimManager.connectExisting(nvimWsUrl: url);
          if (!mounted) return;
          setState(() => _nvim = mgr);
          return;
        } catch (e) {
          _nvimAttempt += 1;
          debugPrint('[vim_editor] nvim connect failed (attempt $_nvimAttempt): $e');
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
    final newUri = widget.control.getString('uri') ?? '';
    final newInitial = widget.control.getString('initial_text') ?? '';
    final curUri = _session?.lspUri ?? '';
    final curInitial = _session?.text ?? '';
    if (newUri != curUri || newInitial != curInitial) {
      print('[vim_editor] didUpdateWidget: prop change — '
          'oldUri="$curUri" newUri="$newUri" '
          'oldLen=${curInitial.length} newLen=${newInitial.length} — '
          're-initializing session');
      _initSession();
      // setState so the build() below picks up the new _session.
      setState(() {});
    }
    _maybeStartLsp();
    _maybeStartNvim();
  }

  @override
  void dispose() {
    _lsp?.stop();
    // NvimManager is process-global (singleton); don't dispose it here.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) return const SizedBox.shrink();
    final modeStr = widget.control.getString('initial_mode') ?? 'native';
    final mode = modeStr == 'nvim'
        ? EditorMode.nvim
        : EditorMode.native;
    return ed.UnifiedEditor(
      session: _session!,
      lsp: _lsp,
      nvim: _nvim,
      initialMode: mode,
      onCancel: () {
        // Same rationale as save: bypass the on_$event flag gate.
        widget.control.triggerEventWithoutSubscribers('cancel', null);
      },
    );
  }
}
