// `UnifiedEditor` — the deliverable.
//
// This widget is what eventually replaces:
//   1. The per-cell formula editor surface (when launched on F2/`=` from
//      the grid).
//   2. The control-code popup (`/edit`).
//   3. The orchestrator's `_python_pane` nvim pane (longer-term — the
//      same widget hosts that view, with a different EditSession bound
//      to the active control's α `code`).
//
// Hosts the chrome + a switchable body (NativeEditor / NvimView). Both
// bodies operate on the SAME EditSession so toggling preserves text +
// dirty + (best-effort) cursor.
//
// Buffer sync between the two editors:
//   - Native ↔ EditSession  : automatic via NativeEditor's controller listener.
//   - Nvim ↔ EditSession    : manual on mode-switch events:
//       switch INTO nvim  → push session.text into nvim buffer (RPC).
//       switch OUT of nvim → pull nvim buffer back into session.text.
//   - `:w` inside nvim       → BufWritePost autocmd → RPC notification
//                              "lab_save" → pull buffer → session.save().
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'edit_session.dart';
import 'editor_chrome.dart';
import 'editor_config.dart';
import 'hover_popup.dart';
import 'log.dart';
import 'lsp_client.dart';
import 'native_editor.dart';
import 'nvim_manager.dart';
import 'nvim_view.dart';
import 'vim_completion_popup.dart';

class UnifiedEditor extends StatefulWidget {
  final EditSession session;
  final NvimManager? nvim;
  final VoidCallback? onCancel;
  final LspClient? lsp;

  /// Initial mode the editor opens in. Native is friendly; users who
  /// prefer Vim flip the chrome switch and stay there per their own
  /// preference (persistence is a v1 concern).
  final EditorMode initialMode;

  /// Called whenever the user toggles between EZ and Vim. Receives
  /// the new mode as a string (`'native'` or `'nvim'`). The host uses
  /// this to persist the user's preference between `/edit` sessions.
  final ValueChanged<String>? onModeChange;

  /// Theme + font + popup geometry + key bindings + hover-doc
  /// fallbacks. Defaults match the lab's shipped behavior; main-repo
  /// integrators pass an `EditorConfig` to retheme/resize/rebind
  /// without forking individual files. See `editor_config.dart`.
  final EditorConfig config;

  const UnifiedEditor({
    super.key,
    required this.session,
    this.nvim,
    this.onCancel,
    this.lsp,
    this.initialMode = EditorMode.native,
    this.onModeChange,
    this.config = const EditorConfig(),
  });

  @override
  State<UnifiedEditor> createState() => _UnifiedEditorState();
}

class _UnifiedEditorState extends State<UnifiedEditor> {
  late EditorMode _mode;
  StreamSubscription? _saveSub;
  StreamSubscription? _textSub;
  Timer? _textChangedDebounce;
  // Heartbeat — polls LSP/nvim health every few seconds so the
  // unmissable health banner appears even when the disconnection is
  // silent (e.g. pygls crashed without sending a final frame, or
  // nvim's RPC went idle).
  Timer? _healthHeartbeat;
  bool _lastLspHealthy = false;
  bool _lastNvimHealthy = false;
  int _vimLspVersion = 1;
  final NativeEditorStateKey _ezKey = NativeEditorStateKey();
  final NvimViewStateKey _vimKey = NvimViewStateKey();
  // Status-bar fields refreshed via setState; the chrome rebuilds
  // when any of these change.
  int _cursorLine = 0;
  int _cursorCol = 0;
  String? _vimMode;
  Timer? _vimModePoll;
  List<LspDiagnostic> _diagnostics = const [];
  void Function(List<LspDiagnostic>, String uri)? _prevDiagHandler;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    // Cmd-/ toggle: re_editor's CodeEditor swallows printable+modified
    // keystrokes at the platform-input layer (TextField), so neither
    // our outer CallbackShortcuts nor an inner Focus.onKeyEvent gets
    // to see Cmd-/ when EZ is focused. Listen on the global hardware
    // keyboard instead — this fires before the focus pipeline routes
    // anything, so the toggle works in both directions identically.
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _healthHeartbeat = Timer.periodic(const Duration(seconds: 3), (_) {
      final lspH = widget.lsp?.isHealthy ?? false;
      final nvimH = widget.nvim?.isHealthy ?? false;
      if (lspH != _lastLspHealthy || nvimH != _lastNvimHealthy) {
        _lastLspHealthy = lspH;
        _lastNvimHealthy = nvimH;
        if (mounted) setState(() {});
      }
    });
    // Subscribe to nvim's :w / text-changed events. Done via
    // `_bindNvimStreams` (not inline) because the nvim manager can now
    // be SWAPPED at runtime — a dropped WebSocket is torn down and
    // reconnected (NvimManager.connectExisting). `didUpdateWidget`
    // re-binds when that happens.
    _bindNvimStreams(widget.nvim);
    if (_mode == EditorMode.nvim) {
      _pushSessionToNvim();
    }
    _bindLspDiagnostics(widget.lsp);
    // Do NOT claim keyboard focus on initial mount. Cmd-E opens the
    // editor as a side panel while the user is still navigating doclet
    // controls (Tab / Ctrl-J); stealing focus here drops the doclet's
    // focus glow and strands the user in nvim. The editor takes focus
    // on an explicit click (`_onPointerDown`) or a mode switch
    // (`_claimEditorFocus` in `_switchMode`) instead.
  }

  /// Last LSP we attached our `_onDiagnostics` callback to. Tracked so
  /// `didUpdateWidget` can detect a change (LSP started async — the
  /// widget was built first with `lsp: null` and the late-arriving
  /// instance must still get its handler wired) and re-bind without
  /// stomping on a different active editor's handler.
  LspClient? _boundLsp;

  /// nvim manager whose `onSave` / `onTextChanged` streams we are
  /// currently subscribed to. Tracked so `didUpdateWidget` can detect
  /// a manager swap (reconnect after a dropped WebSocket) and rebind —
  /// the old manager's streams are closed by `NvimManager.stop()`, so
  /// without rebinding `:w`-to-save and live diagnostics would silently
  /// stop working after a reconnect.
  NvimManager? _boundNvim;

  void _bindNvimStreams(NvimManager? nvim) {
    if (identical(nvim, _boundNvim)) return;
    _boundNvim = nvim;
    _saveSub?.cancel();
    _textSub?.cancel();
    _saveSub = null;
    _textSub = null;
    if (nvim == null) return;
    // :w inside the Vim view → pull the buffer back into the session
    // and fire session.save. Use `widget.nvim?.rpc` (not a captured
    // ref) so the call always targets the live manager.
    _saveSub = nvim.onSave.listen((_) async {
      final rpc = widget.nvim?.rpc;
      if (rpc == null) return;
      try {
        final text = await rpc.getBufferText();
        widget.session.setText(text);
        await widget.session.save();
      } catch (e) {
        debugPrint('[unified] :w pull failed: $e');
      }
    });
    // nvim's TextChanged* autocmd → pull the new text and push it to
    // the LSP via didChange so diagnostics update. Debounced 80ms so a
    // burst of keystrokes coalesces into one round-trip.
    _textSub = nvim.onTextChanged.listen((_) {
      _textChangedDebounce?.cancel();
      _textChangedDebounce =
          Timer(const Duration(milliseconds: 80), () async {
        if (_mode != EditorMode.nvim) return; // only when actually in vim
        final rpc = widget.nvim?.rpc;
        final lsp = widget.lsp;
        if (rpc == null || lsp == null) return;
        try {
          final text = await rpc.getBufferText();
          lsp.didChange(_ourUri(), text, version: ++_vimLspVersion);
        } catch (e) {
          debugPrint('[unified] vim text-changed didChange failed: $e');
        }
      });
    });
  }

  void _bindLspDiagnostics(LspClient? lsp) {
    if (identical(lsp, _boundLsp)) return;
    if (_boundLsp != null && _boundLsp!.onDiagnostics == _onDiagnostics) {
      _boundLsp!.onDiagnostics = _prevDiagHandler;
    }
    _boundLsp = lsp;
    if (lsp != null) {
      _prevDiagHandler = lsp.onDiagnostics;
      lsp.onDiagnostics = _onDiagnostics;
      labLog('[lab.diag] bound onDiagnostics to LSP');
    }
  }

  @override
  void didUpdateWidget(covariant UnifiedEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lsp, widget.lsp)) {
      _bindLspDiagnostics(widget.lsp);
    }
    // nvim manager swapped — reconnect after a dropped WebSocket
    // produces a fresh NvimManager. Rebind the :w / text-changed
    // streams onto it (the old manager's streams are now closed).
    if (!identical(oldWidget.nvim, widget.nvim)) {
      _bindNvimStreams(widget.nvim);
    }
    // Session swap (e.g., second `/edit <name>` from the orchestrator
    // built a fresh EditSession with a different URI / initial text).
    // Without this branch, the inner nvim buffer stays on the prior
    // session's content even though the chrome (label/URI) updates to
    // reflect the new target — the bug where editing `principal` and
    // then `years` showed `principal.code` content under a `years.code`
    // title bar.
    if (!identical(oldWidget.session, widget.session)) {
      final oldUri = oldWidget.session.lspUri;
      final newUri = widget.session.lspUri;
      labLog('[unified] didUpdateWidget: session swap '
          'oldUri="$oldUri" newUri="$newUri" '
          'newLen=${widget.session.text.length}');
      // Diagnostics from the previous session don't apply.
      setState(() => _diagnostics = []);
      // Push fresh buffer into nvim. Skips when not in vim mode; we'll
      // hit it on the next mode toggle. Also fire when mode is native
      // so nvim is primed if the user toggles to Vim.
      _pushSessionToNvim();
      // The native CodeEditor's State watches widget.session.text via
      // Flutter's normal rebuild path — the build() below re-creates
      // CodeEditor with the new session, so EZ mode picks up the new
      // content automatically.
    }
  }

  void _onDiagnostics(List<LspDiagnostic> diags, String uri) {
    // Filter to our session's uri only — the LSP client is shared
    // across sessions, so other docs' diagnostics show up here too.
    final ourUri = _ourUri();
    labLog('[lab.diag] publish uri=$uri ourUri=$ourUri count=${diags.length}');
    if (uri != ourUri) {
      _prevDiagHandler?.call(diags, uri);
      return;
    }
    if (!mounted) return;
    labLog('[lab.diag] received ${diags.length} diagnostics for $ourUri');
    setState(() => _diagnostics = diags);
    _renderVimDiagnostics(diags);
  }

  /// LSP URI for the session. Single source of truth lives on
  /// `EditSession.lspUri` so production callers can pass real
  /// (controlName, attribute, columnName) without going through label
  /// sanitization.
  String _ourUri() => widget.session.lspUri;

  /// Push diagnostics into nvim. Dual path:
  ///   (1) signs (sign_place) — visible glyph in the gutter even when
  ///       not on the line. This is the mechanism that was working
  ///       intermittently before; restoring it as the baseline.
  ///   (2) extmark underlines (nvim_buf_set_extmark) — wavy-line on
  ///       the offending range. Skipped if extmark fails (older nvim).
  /// Both are scoped to a stable namespace so unplace/clear is atomic.
  Future<void> _renderVimDiagnostics(List<LspDiagnostic> diags) async {
    final mgr = widget.nvim;
    final rpc = mgr?.rpc;
    if (rpc == null) {
      labLog('[lab.diag] vim render skipped: no rpc');
      return;
    }
    final ns = mgr?.diagNs;
    if (ns == null) {
      labLog('[lab.diag] vim render skipped: no namespace');
      return;
    }
    try {
      final buf = await _curBuf(rpc);
      final list = diags.map((d) => {
            'line': d.line,
            'end_line': d.endLine,
            'col': d.startCol,
            'end_col': d.endCol,
            'severity': d.severity,
            'message': d.message,
          }).toList();
      // One Lua chunk: clear our namespace's signs+extmarks for this
      // buffer, then place new ones. Returns a verification dict so the
      // Dart side can log what nvim actually accepted.
      final lua = r'''
local ns, buf, list = ...
-- Clear prior signs+extmarks for our namespace.
pcall(vim.fn.sign_unplace, 'lab', { buffer = buf })
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
-- Idempotent sign definitions (highlight groups that exist by
-- default in nvim and are intended for diagnostic display).
pcall(vim.fn.sign_define, 'lab_err',  {text = 'E', texthl = 'DiagnosticSignError'})
pcall(vim.fn.sign_define, 'lab_warn', {text = 'W', texthl = 'DiagnosticSignWarn'})
pcall(vim.fn.sign_define, 'lab_info', {text = 'i', texthl = 'DiagnosticSignInfo'})
-- Helper: clamp end_col to the actual line length so extmark doesn't
-- silently fail with "col out of range" on diagnostics that point
-- past the end of the line (common with parser errors at EOL).
local function clamp_col(line_idx, col)
  local lines = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)
  local maxlen = (lines[1] and #lines[1]) or 0
  if col == nil or col > maxlen then return maxlen end
  if col < 0 then return 0 end
  return col
end
local placed_signs = 0
local placed_marks = 0
local extmark_err = nil
for _, d in ipairs(list) do
  local sev = d.severity or 1
  local sign_name = sev == 1 and 'lab_err' or (sev == 2 and 'lab_warn' or 'lab_info')
  -- Highlight groups for the buffer underline / virtual text. These
  -- are the standard nvim-diagnostic groups; even minimal colorschemes
  -- define them visibly. ErrorMsg / WarningMsg are NOT appropriate
  -- here — those are for the command-line message area.
  local under_hl = sev == 1 and 'DiagnosticUnderlineError'
              or (sev == 2 and 'DiagnosticUnderlineWarn'
              or 'DiagnosticUnderlineInfo')
  local virt_hl = sev == 1 and 'DiagnosticVirtualTextError'
              or (sev == 2 and 'DiagnosticVirtualTextWarn'
              or 'DiagnosticVirtualTextInfo')
  -- Sign in the gutter (always lnum is 1-indexed for sign_place).
  local ok = pcall(vim.fn.sign_place, 0, 'lab', sign_name, buf, { lnum = d.line + 1 })
  if ok then placed_signs = placed_signs + 1 end
  -- Extmark with EOL virtual text + underline highlight on range.
  -- Clamp end_col to avoid "col out of range" failures.
  local end_row = d.end_line or d.line
  local start_col = clamp_col(d.line, d.col or 0)
  local end_col = clamp_col(end_row, d.end_col)
  -- Zero-width diagnostics (e.g. SyntaxError on `the.` — the parser
  -- flags the trailing `.` with start==end at EOL) leave nvim with
  -- nothing to underline. Walk backward from start_col through any
  -- contiguous run of identifier/dot characters so the squiggle
  -- spans the offending token. If nothing nearby looks identifier-y,
  -- fall back to underlining the whole line.
  if end_row == d.line and start_col >= end_col then
    local lines = vim.api.nvim_buf_get_lines(buf, d.line, d.line + 1, false)
    local line_text = lines[1] or ''
    local line_len = #line_text
    end_col = math.max(start_col, math.min(start_col + 1, line_len))
    -- start_col can be past EOL if pygls reported it that way; clamp.
    if start_col > line_len then start_col = line_len end
    -- Walk back through identifier/dot chars to find a real range.
    local s = start_col
    while s > 0 do
      local ch = line_text:sub(s, s)
      if ch:match("[%w_%.]") then s = s - 1 else break end
    end
    if s < start_col then
      start_col = s
    elseif end_col == start_col then
      -- Nothing identifier-like nearby — underline the whole line.
      start_col = 0
      end_col = line_len > 0 and line_len or 1
    end
  end
  local ok2, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, d.line, start_col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = under_hl,
    virt_text = {{ ' ■ ' .. (d.message or ''), virt_hl }},
    virt_text_pos = 'eol',
    priority = 200,
  })
  if ok2 then placed_marks = placed_marks + 1 else extmark_err = tostring(err) end
end
-- Force a redraw so the diagnostic underline updates flush as a
-- single redraw event rather than waiting for the next user input.
pcall(vim.cmd, 'redraw')
local cur_buf = vim.api.nvim_get_current_buf()
return {
  signs = placed_signs,
  marks = placed_marks,
  cur_buf = cur_buf,
  buf_name = vim.api.nvim_buf_get_name(buf),
  bufferft = vim.api.nvim_buf_get_option(buf, 'filetype'),
  syntax = vim.api.nvim_buf_get_option(buf, 'syntax'),
  extmark_err = extmark_err,
}
''';
      final res = await rpc.request('nvim_exec_lua', [lua, [ns, buf, list]]);
      labLog('[lab.diag] vim render ns=$ns buf=$buf '
          'count=${list.length} result=$res');
    } catch (e, st) {
      debugPrint('[lab.diag] vim diagnostic render failed: $e\n$st');
    }
  }

  Future<int> _curBuf(dynamic rpc) async {
    // nvim_get_current_buf returns a Buffer object via msgpack EXT
    // type (code 0), which msgpack_dart decodes as null. bufnr('%')
    // returns the same buffer as a plain integer — works through
    // the Deserializer cleanly.
    final b = await rpc.request('nvim_call_function', ['bufnr', ['%']]);
    return b is num ? b.toInt() : 0;
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.slash) return false;
    final modOk = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (!modOk) return false;
    _toggleMode();
    return true; // claim the event so re_editor doesn't insert `/`
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _saveSub?.cancel();
    _textSub?.cancel();
    _textChangedDebounce?.cancel();
    _healthHeartbeat?.cancel();
    _vimModePoll?.cancel();
    // Both popups own static OverlayEntries that aren't tied to any
    // widget's State — if UnifiedEditor unmounts with one of them
    // open, the overlay leaks (and HoverPopup's HardwareKeyboard
    // handler stays installed forever). Dismiss explicitly here.
    HoverPopup.dismiss();
    VimCompletionPopup.dismiss();
    // Use the LSP we actually bound to (`_boundLsp`), not `widget.lsp`
    // — they can differ if the LSP came online after initState.
    final lsp = _boundLsp;
    if (lsp != null && lsp.onDiagnostics == _onDiagnostics) {
      lsp.onDiagnostics = _prevDiagHandler;
    }
    super.dispose();
  }

  /// Poll nvim's mode while we're in Vim view so the status bar can
  /// show NORMAL / INSERT / VISUAL / etc. Cheap RPC call (~1ms); 250ms
  /// cadence keeps the indicator responsive without flooding the bus.
  void _startVimModePoll() {
    _vimModePoll?.cancel();
    _vimModePoll = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (!mounted || _mode != EditorMode.nvim) return;
      final rpc = widget.nvim?.rpc;
      if (rpc == null) return;
      try {
        // Mode + cursor in two cheap RPCs — both fire on the same
        // tick so the status bar stays consistent.
        final m = await rpc.request('nvim_get_mode', []);
        String? newMode;
        if (m is Map && m['mode'] is String) {
          newMode = _modeLabel((m['mode'] as String));
        }
        final cur = await rpc.getCursor();
        if (!mounted) return;
        final modeChanged = newMode != null && newMode != _vimMode;
        final curChanged =
            cur.$1 != _cursorLine || cur.$2 != _cursorCol;
        if (modeChanged || curChanged) {
          setState(() {
            if (modeChanged) _vimMode = newMode;
            if (curChanged) {
              _cursorLine = cur.$1;
              _cursorCol = cur.$2;
            }
          });
        }
      } catch (_) {}
    });
  }

  void _stopVimModePoll() {
    _vimModePoll?.cancel();
    _vimModePoll = null;
    if (_vimMode != null) setState(() => _vimMode = null);
  }

  String _modeLabel(String code) {
    // Common mode codes — full table at :help mode().
    if (code.startsWith('n')) return 'NORMAL';
    if (code.startsWith('i')) return 'INSERT';
    if (code.startsWith('v')) return 'VISUAL';
    if (code == 'V') return 'V-LINE';
    if (code == '' || code.startsWith('')) return 'V-BLOCK';
    if (code.startsWith('R')) return 'REPLACE';
    if (code.startsWith('c')) return 'COMMAND';
    if (code.startsWith('t')) return 'TERMINAL';
    return code.toUpperCase();
  }

  Future<void> _pushSessionToNvim() async {
    final rpc = widget.nvim?.rpc;
    if (rpc == null) return;
    try {
      // Buffer name = synthetic URL keyed by session label so the
      // status line in vim shows what we're editing, and the
      // lab_save notification arrives with a useful bufname.
      final safe = widget.session.label
          .replaceAll(RegExp(r'[^A-Za-z0-9_./-]'), '_');
      final bufName = 'lab://${safe.isEmpty ? "session" : safe}.py';
      labLog('[lab] _pushSessionToNvim: name=$bufName text_len=${widget.session.text.length}');
      // .py extension here so nvim's filetype detection lands on Python
      // even before the explicit `filetype=python` re-assertion in
      // setBufferText. Belt-and-suspenders: the rename fires a
      // BufFilePost autocmd that re-runs ftdetect; with `.py`, the
      // detection succeeds; without it, ftdetect produces nothing and
      // syntax highlighting silently dies.
      await rpc.setBufferText(widget.session.text, name: bufName);
      // Verify post-push state — confirm filetype landed and the buffer
      // we wrote to is the one nvim is showing. If filetype != python
      // or cur_buf != our_buf, that's the regression.
      try {
        final verify = await rpc.request('nvim_exec_lua', [
          r'''
local cur = vim.api.nvim_get_current_buf()
return {
  cur_buf = cur,
  buf_name = vim.api.nvim_buf_get_name(cur),
  filetype = vim.api.nvim_buf_get_option(cur, 'filetype'),
  buftype  = vim.api.nvim_buf_get_option(cur, 'buftype'),
  syntax   = vim.api.nvim_buf_get_option(cur, 'syntax'),
}
''',
          [],
        ]);
        labLog('[lab] post-push state: $verify');
      } catch (_) {}
    } catch (e) {
      debugPrint('[unified] push session→nvim failed: $e');
    }
  }

  Future<void> _pullNvimToSession() async {
    final rpc = widget.nvim?.rpc;
    if (rpc == null) return;
    try {
      final text = await rpc.getBufferText();
      // Use the default markDirty=true: setText short-circuits if the
      // text didn't actually change (no-op switch in/out without
      // editing leaves dirty alone), and flips dirty true if vim
      // actually modified the buffer (which is the right semantic —
      // unsaved vim edits should show the unsaved indicator after
      // switching back to native).
      widget.session.setText(text);
    } catch (e) {
      debugPrint('[unified] pull nvim→session failed: $e');
    }
  }

  Future<void> _setMode(EditorMode mode) async {
    if (mode == _mode) return;
    final prev = _mode;
    labLog('[lab] _setMode: $prev -> $mode');
    // Notify the host so it can persist the user's preference and
    // open the next `/edit` in the same mode. Done before the actual
    // swap so the host sees the intended state immediately, even if
    // the buffer transfer below fails mid-way.
    widget.onModeChange?.call(mode == EditorMode.nvim ? 'nvim' : 'native');
    // Tear down any open completion / hover popups before swapping
    // bodies — re_editor's CodeAutocomplete keeps its OverlayEntry in
    // the root overlay, and our VimCompletionPopup does the same, so
    // both will visually leak across the mode switch unless we dismiss
    // them here.
    VimCompletionPopup.dismiss();
    HoverPopup.dismiss();
    // EZ's autocomplete uses a CompositedTransformFollower with
    // `showWhenUnlinked: false`, so unlinking the LeaderLayer is
    // enough — but Offstage doesn't always cleanly remove the leader
    // before the popup paints once more. Drop the primary focus first
    // so re_editor's TapRegion sees a focus-loss, which in practice
    // makes the overlay vanish at the next frame.
    FocusManager.instance.primaryFocus?.unfocus();

    // Snapshot cursor BEFORE flipping the mode — we'll mirror it onto
    // the destination editor after the buffer sync lands.
    (int, int)? cursorFromEz;
    (int, int)? cursorFromVim;
    if (prev == EditorMode.native) {
      cursorFromEz = _ezKey.currentState?.getCursor();
    } else if (prev == EditorMode.nvim) {
      try {
        cursorFromVim = await widget.nvim?.rpc?.getCursor();
      } catch (_) {}
    }

    setState(() => _mode = mode);

    if (prev == EditorMode.nvim && mode == EditorMode.native) {
      _stopVimModePoll();
      await _pullNvimToSession();
      final cv = cursorFromVim;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (cv != null) {
          _ezKey.currentState?.setCursor(cv.$1, cv.$2);
          setState(() {
            _cursorLine = cv.$1;
            _cursorCol = cv.$2;
          });
        }
      });
      _claimEditorFocus();
    } else if (prev == EditorMode.native && mode == EditorMode.nvim) {
      await _pushSessionToNvim();
      try {
        await widget.nvim?.rpc?.request('nvim_input', [r'<C-\><C-n>']);
      } catch (_) {}
      final ce = cursorFromEz;
      if (ce != null) {
        await widget.nvim?.rpc?.setCursor(ce.$1, ce.$2);
        setState(() {
          _cursorLine = ce.$1;
          _cursorCol = ce.$2;
        });
      }
      _startVimModePoll();
      _claimEditorFocus();
    }
  }

  /// After a mode switch, hand keyboard focus to whichever body the
  /// chrome flipped to. Belt-and-suspenders: a postFrame call (so the
  /// Offstage swap and re-mount happen first) PLUS a 50ms delayed
  /// retry. The delay matters because the GestureDetector tap that
  /// triggered the switch hasn't fully released its press state yet
  /// when postFrame runs — without the retry, Flutter's focus
  /// traversal can land on the toggle button after our requestFocus.
  void _claimEditorFocus() {
    void grab() {
      if (!mounted) return;
      if (_mode == EditorMode.native) {
        _ezKey.currentState?.grabFocus();
      } else {
        _vimKey.currentState?.grabFocus();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => grab());
    Future.delayed(const Duration(milliseconds: 50), grab);
    Future.delayed(const Duration(milliseconds: 150), grab);
  }

  @override
  Widget build(BuildContext context) {
    // Single LSP URI for both editors — drives `resolve_context()` on
    // the server side (control name, attribute='code', column when
    // applicable). Built once in EditSession from real identity fields,
    // so the lab and a real Property both produce a URI the server
    // understands.
    final uri = widget.session.lspUri;
    final native = NativeEditor(
      key: _ezKey,
      session: widget.session,
      lsp: widget.lsp,
      uri: uri,
      diagnostics: _diagnostics,
      onToggleMode: _toggleMode,
      onCursor: (l, c) {
        if (_mode == EditorMode.native) {
          if (l != _cursorLine || c != _cursorCol) {
            setState(() {
              _cursorLine = l;
              _cursorCol = c;
            });
          }
        }
      },
    );
    final nvim = NvimView(
      key: _vimKey,
      session: widget.session,
      manager: widget.nvim,
      lsp: widget.lsp,
      uri: uri,
      active: _mode == EditorMode.nvim,
      onToggleMode: _toggleMode,
    );

    // CRITICAL: do NOT gate `save` on `widget.session.dirty` here.
    // `UnifiedEditor.build` runs once per setState (mode change,
    // diagnostics, cursor); when the user types in the EZ editor,
    // `session.dirty` flips inside an `AnimatedBuilder` that rebuilds
    // the chrome's internals but NOT the `actions` object passed to
    // it — so a stale `save: null` survives forever, and the save
    // button silently does nothing. Always wire `save` to a closure
    // that reads `session.dirty` AT CLICK TIME, so dirty-state
    // changes after the build are honored without rebuilding.
    final actions = EditorActions(
      save: _doSave,
      cancel: widget.onCancel,
      undo: _doUndo,
      redo: _doRedo,
      hover: _doShowHover,
    );
    // Look up first diagnostic that overlaps the current cursor line.
    LspDiagnostic? cursorDiag;
    for (final d in _diagnostics) {
      if (d.line <= _cursorLine && _cursorLine <= d.endLine) {
        cursorDiag = d;
        break;
      }
    }
    // Health-based — `isHealthy` checks both connection alive AND
    // recent activity, so a long-silent LSP that hasn't actually died
    // still shows as down. Without this, "completions silently
    // stopped working" had no visible signal in the UI.
    final lspHealthy = widget.lsp?.isHealthy ?? false;
    final nvimHealthy = widget.nvim?.isHealthy ?? false;
    final status = EditorStatus(
      cursorLine: _cursorLine,
      cursorCol: _cursorCol,
      lspConnected: lspHealthy,
      nvimConnected: nvimHealthy,
      lspError: lspHealthy ? null : widget.lsp?.lastError,
      nvimError: nvimHealthy ? null : widget.nvim?.lastError,
      mode: _vimMode,
      diagnosticMessage: cursorDiag?.message,
      diagnosticSeverity: cursorDiag?.severity,
    );

    final keys = widget.config.keys;
    return CallbackShortcuts(
      bindings: {
        keys.showHoverDocs: _doShowHover,
        keys.showHoverDocsCtrl: _doShowHover,
        // Cmd-/ here is best-effort (re_editor/nvim usually swallow
        // printable+modified keys). The reliable path is the global
        // HardwareKeyboard handler set up in initState.
        keys.toggleMode: _toggleMode,
        keys.toggleModeCtrl: _toggleMode,
        // Cmd-S / Ctrl-S → save. Mirrors the toolbar save button.
        keys.save: _doSave,
        keys.saveCtrl: _doSave,
      },
      child: EditorChrome(
        session: widget.session,
        mode: _mode,
        onModeChange: _setMode,
        actions: actions,
        status: status,
        body: Stack(
          // StackFit.expand forces children to fill the Stack's bounded
          // area. Without it, Offstage-wrapped children get loose
          // constraints (0 ≤ size ≤ parent) and re_editor's CodeEditor
          // collapses to height 0 — chrome renders, editor body is
          // invisible (parent's black bg shows through).
          fit: StackFit.expand,
          children: [
            Offstage(offstage: _mode != EditorMode.native, child: native),
            Offstage(offstage: _mode != EditorMode.nvim, child: nvim),
          ],
        ),
      ),
    );
  }

  /// Save the buffer back to the host.
  ///
  /// In vim mode the live buffer text lives in `nvim`, NOT in
  /// `session._text` (which was last set when entering vim). The
  /// autocmd `:w` path pulls from nvim before save via `_saveSub`; the
  /// toolbar Save button and Cmd-S shortcut must do the same — without
  /// the pull they'd ship the stale pre-vim text and the user's vim
  /// edits would appear to be silently dropped. NativeEditor's
  /// controller listener keeps `session._text` in sync continuously,
  /// so EZ mode needs no pull.
  Future<void> _doSave() async {
    if (_mode == EditorMode.nvim) {
      await _pullNvimToSession();
    }
    await widget.session.save();
  }

  Future<void> _doUndo() async {
    if (_mode == EditorMode.native) {
      _ezKey.currentState?.undo();
    } else {
      try {
        await widget.nvim?.rpc?.request('nvim_input', ['u']);
      } catch (_) {}
    }
  }

  Future<void> _doRedo() async {
    if (_mode == EditorMode.native) {
      _ezKey.currentState?.redo();
    } else {
      try {
        await widget.nvim?.rpc?.request('nvim_input', [r'<C-r>']);
      } catch (_) {}
    }
  }

  void _toggleMode() {
    _setMode(_mode == EditorMode.native ? EditorMode.nvim : EditorMode.native);
  }

  /// Cmd-K hover-docs entry point. Walks BACK through identifier-like
  /// tokens on the current line (right-to-left from the cursor) and
  /// asks the LSP for hover at each candidate site. Returns at the
  /// first one with a non-empty response; falls back to local
  /// fallback notes / empty-message panel if every probe is empty.
  /// Handles `the.cell.bg = f'##` (cursor at end) by skipping `f`,
  /// the inside-string position, etc., and landing on `bg`.
  Future<void> _doShowHover() async {
    // Cmd-K is a toggle: if the hover popup is already open, dismiss
    // it (same affordance as Esc). Without this, pressing Cmd-K twice
    // is a no-op — the second show() finds an open panel and either
    // ignores it or refetches at the same location. Toggling is the
    // mental model users expect from "open docs / now hide docs".
    if (HoverPopup.isOpen) {
      HoverPopup.dismiss();
      return;
    }
    final candidates = _hoverCandidates();
    final lsp = widget.lsp;
    final uri = widget.session.lspUri;
    String? bestWord;
    int? bestLine;
    int? bestCol;
    String body = '';
    if (lsp != null) {
      for (final c in candidates) {
        try {
          final docs = (await lsp.hover(uri, c.line, c.col)).trim();
          if (docs.isNotEmpty) {
            body = docs;
            bestWord = c.word;
            bestLine = c.line;
            bestCol = c.col;
            break;
          }
        } catch (_) {
          // ignore probe failures, keep walking
        }
      }
    }
    if (!mounted) return;
    // If nothing came back, surface the rightmost candidate's word so
    // the local fallback dict + empty-note can use it.
    final fallback = candidates.isNotEmpty ? candidates.first : null;
    HoverPopup.requestAt(context,
        line: bestLine ?? fallback?.line ?? _cursorLine,
        col: bestCol ?? fallback?.col ?? _cursorCol,
        uri: uri,
        lsp: body.isEmpty ? lsp : null, // skip a duplicate fetch
        preFetched: body.isEmpty ? null : body,
        word: bestWord ?? fallback?.word,
        extraFallbacks: widget.config.hoverFallbacks,
        onDismissed: _claimEditorFocus);
  }

  /// Build the right-to-left list of candidate (line, col, word) sites
  /// to probe for hover docs on the current line. Cursor-position
  /// identifier first, then each preceding identifier token.
  List<({int line, int col, String word})> _hoverCandidates() {
    final pair = _lineAndCursorForActiveEditor();
    if (pair == null) return const [];
    final lineText = pair.text;
    final cursorCol = pair.col;
    final out = <({int line, int col, String word})>[];
    // Cursor-position identifier (if any).
    final hit = _identifierRangeAt(lineText, cursorCol);
    int scanFrom = cursorCol;
    if (hit != null) {
      out.add((
        line: _cursorLine,
        col: hit.end,
        word: lineText.substring(hit.start, hit.end),
      ));
      scanFrom = hit.start; // continue to the LEFT of this run
    }
    // All preceding identifier runs, right-to-left.
    var probe = scanFrom - 1;
    while (probe >= 0) {
      final h = _identifierRangeAt(lineText, probe);
      if (h != null) {
        out.add((
          line: _cursorLine,
          col: h.end,
          word: lineText.substring(h.start, h.end),
        ));
        probe = h.start - 1;
        continue;
      }
      probe--;
    }
    return out;
  }

  ({String text, int col})? _lineAndCursorForActiveEditor() {
    if (_mode == EditorMode.native) {
      final t = _ezKey.currentState?.lineAtCursor();
      if (t == null) return null;
      return (text: t, col: _cursorCol);
    }
    return _vimKey.currentState?.lineAndCursorSync();
  }

  /// If position `col` is inside or at the boundary of an identifier
  /// run on `line`, returns its (start, end) bounds; otherwise null.
  ({int start, int end})? _identifierRangeAt(String line, int col) {
    if (col < 0 || col > line.length) return null;
    bool isWord(int c) =>
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5f;
    var l = col;
    while (l > 0 && isWord(line.codeUnitAt(l - 1))) {
      l--;
    }
    var r = col;
    while (r < line.length && isWord(line.codeUnitAt(r))) {
      r++;
    }
    if (l == r) return null;
    return (start: l, end: r);
  }

}
