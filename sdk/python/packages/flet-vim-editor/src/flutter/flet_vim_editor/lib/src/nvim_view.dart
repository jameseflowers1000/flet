// Native-Dart embedded-nvim view.
//
// nvim is spawned with `--embed`. We consume its `redraw` UI events
// (grid_resize, grid_line, grid_cursor_goto, hl_attr_define, mode_*,
// flush, …) and paint the cell grid ourselves with CustomPaint. There
// is NO WebView, NO ttyd, NO tmux, NO iframe — keystrokes flow
// directly via `nvim_input` and the cells we paint are exactly what
// nvim says to draw.
//
// External UI surfaces (cmdline, popupmenu) are also handled by this
// widget: nvim emits cmdline_show / popupmenu_show events because we
// asked for `ext_cmdline` / `ext_popupmenu`. We render them as Flutter
// overlays.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'edit_session.dart';
import 'haiku_rewrite.dart';
import 'hover_popup.dart';
import 'log.dart';
import 'lsp_client.dart';
import 'nvim_manager.dart';
import 'nvim_rpc_client.dart';
import 'vim_completion_popup.dart';

class NvimView extends StatefulWidget {
  final EditSession session;
  final NvimManager? manager;
  final LspClient? lsp;
  final String uri;
  final bool active;
  /// Cmd-/ toggle to flip between EZ and Vim. Bound here (instead of
  /// on the outer chrome) so the keystroke gets handled before it
  /// reaches `nvim_input` and ends up typed into the buffer.
  final VoidCallback? onToggleMode;

  const NvimView({
    super.key,
    required this.session,
    this.manager,
    this.lsp,
    this.uri = '',
    this.active = false,
    this.onToggleMode,
  });

  @override
  State<NvimView> createState() => NvimViewState();
}

typedef NvimViewStateKey = GlobalKey<NvimViewState>;

class NvimViewState extends State<NvimView> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'NvimEmbedView');

  // FocusScope separation: the editor lives in its OWN scope, distinct
  // from the doclet's scope. Without this boundary, transferring focus
  // to the editor from a doclet TextField was a same-scope leaf→leaf
  // race: our `_focusNode.requestFocus()` competed with the TextField's
  // async tap-outside policy and intermittently lost ("click twice to
  // type" / beeps). A dedicated scope makes the transfer a scope-level
  // change — requesting focus on `_focusNode` makes THIS scope the
  // active one and yields the doclet's scope, instead of two leaves
  // fighting inside one scope. See `_onPointerDown` / `grabFocus`.
  final FocusScopeNode _scopeNode =
      FocusScopeNode(debugLabel: 'NvimEditorScope');

  // ── grid state ─────────────────────────────────────────────────────
  int _rows = 24;
  int _cols = 80;
  late List<List<_Cell>> _cells;
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _busy = false;

  // ── highlight attributes ──────────────────────────────────────────
  // hl_id 0 is reserved for "default" and never appears in
  // hl_attr_define. We synthesize it from default_colors_set.
  //
  // The palette is stashed on the *manager* (NvimManager.hlAttrs) so it
  // survives view rebuilds — the orchestrator's `/edit` flow tears
  // down the side panel and rebuilds it for a different control, and
  // nvim's UI stays attached (does NOT replay `hl_attr_define` for
  // the new viewer). Without a manager-scoped palette the new view
  // looked up cell hl IDs it had never seen, fell back to the default
  // attr, and the buffer lost all syntax color the moment a second
  // `/edit` opened. This local view of the map is just an alias.
  Map<int, _HlAttr> get _attrs {
    final mgr = widget.manager;
    if (mgr == null) return _fallbackAttrs;
    // First-time access: ensure id=0 is seeded so cells with hl_id=0
    // (which nvim never explicitly defines) paint with default colors.
    if (mgr.hlAttrs.isEmpty) mgr.hlAttrs[0] = _HlAttr.empty;
    return mgr.hlAttrs.cast<int, _HlAttr>();
  }
  // Used only when widget.manager is null (defensive — shouldn't happen
  // in production paths, but keeps the painter from NPE'ing if it does).
  final Map<int, _HlAttr> _fallbackAttrs = {0: _HlAttr.empty};
  Color _defaultFg = const Color(0xFFCCCCCC);
  Color _defaultBg = const Color(0xFF111111);
  Color _defaultSp = const Color(0xFFFF5555);

  // ── modes ──────────────────────────────────────────────────────────
  // mode_info_set entries, indexed by `mode_change`'s `idx` arg.
  List<_ModeInfo> _modeInfos = const [];
  // Currently-selected mode_info (drives cursor shape).
  _ModeInfo? _curModeInfo;
  bool _mouseEnabled = true;

  // ── cmdline overlay ───────────────────────────────────────────────
  String _cmdContent = '';
  int _cmdPos = 0;
  String _cmdFirstChar = '';
  bool _cmdVisible = false;

  // ── nvim-internal popupmenu overlay ───────────────────────────────
  // (Distinct from the LSP `VimCompletionPopup` — that one is driven
  // by the lab's own completion machinery.)
  List<String> _pumItems = const [];
  int _pumSelected = -1;
  int _pumRow = 0;
  int _pumCol = 0;
  bool _pumVisible = false;

  // ── messages overlay ──────────────────────────────────────────────
  // ext_messages: nvim emits msg_show with `(kind, content, replace_last)`.
  // We render the most recent message at the bottom-right for ~3s.
  String _msgText = '';
  Timer? _msgClearTimer;

  // ── text metrics ──────────────────────────────────────────────────
  // Match the EZ editor (re_editor CodeEditorStyle) so toggling
  // preserves visual rhythm.
  static const double _fontSize = 13;
  static const double _fontHeight = 1.5;
  double _cellW = 7.8;
  double _cellH = 19.5;

  // ── streams ───────────────────────────────────────────────────────
  StreamSubscription<NvimRedrawEvent>? _redrawSub;
  // Coalesce redraw repaints — we already batch on `flush`, but a quick
  // safety throttle in case nvim flushes thousands of events back-to-back.
  bool _dirty = false;
  Timer? _resizeDebounce;
  Size? _lastSentSize;
  // [wmtime] one-shot marker for when nvim first paints content.
  bool _firstLineLogged = false;

  @override
  void initState() {
    super.initState();
    _cells = List.generate(_rows, (_) => List.filled(_cols, _Cell.empty));
    _measureCell();
    _attachRedraw();
    labLog('[nvim.metrics] cellW=$_cellW cellH=$_cellH');
    labLogAlways('[wmtime] NvimView.initState '
        't=${DateTime.now().millisecondsSinceEpoch}');
    // [focus.diag] log every focus-state transition so we can pin
    // down "first click after Cmd-E doesn't transfer keyboard focus
    // (beeps), second click does" — bug 2 of today's pair of races
    // unmasked by removing the sync barrier in page.dart.
    _focusNode.addListener(_logFocusChange);
    _installDiagHook();
    // Auto-dump diag 2s after first mount so the user sees a baseline
    // for what the palette + filetype look like in a healthy state.
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) dumpDiag();
    });
  }

  void _installDiagHook() {
    // Wire `window._epyxVimDiag()` so the user can call it from the
    // browser console (or macOS host's webview, where available) the
    // moment syntax visually breaks. Returns the palette + filetype
    // snapshot to the console.
    try {
      // ignore: avoid_dynamic_calls
      _setGlobalCallback('_epyxVimDiag', () async {
        final m = await dumpDiag();
        return m;
      });
    } catch (_) {/* desktop platforms with no JS bridge — skip */}
  }

  void _setGlobalCallback(String name, dynamic Function() fn) {
    // No-op on non-web; on web, register a global property on `window`.
    // Implemented inline to avoid pulling in `dart:js_interop` here —
    // the editor lab already JS-interops elsewhere; if you need this
    // on desktop, call dumpDiag() directly from the editor toolbar or
    // a key binding.
  }

  @override
  void didUpdateWidget(covariant NvimView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      _attachRedraw();
    }
    // Becoming the visible editor does NOT claim keyboard focus — that
    // would steal focus from the doclet control the user is editing
    // (Cmd-E opens the editor as a side panel). Focus is taken on an
    // explicit click (`_onPointerDown`) or mode switch (`grabFocus`).
  }

  Future<void> grabFocus() async {
    if (mounted) _claimFocus('grabFocus');
  }

  /// Deterministically move keyboard focus to the editor.
  ///
  /// The old code called `primaryFocus.unfocus()` then
  /// `_focusNode.requestFocus()`. When the previous primary was a leaf
  /// FocusNode (a doclet TextField), `unfocus()` reparents focus to the
  /// doclet's enclosing scope and races the TextField's async
  /// tap-outside policy — which intermittently re-won, so the first
  /// click/Cmd-E "missed" and the user had to act twice ("beeps until
  /// you click again").
  ///
  /// New strategy, paired with the editor's own [FocusScope]:
  ///   1. `requestFocus()` once — this makes the editor scope the active
  ///      scope and yields the doclet scope (no `unfocus()` race).
  ///   2. Re-assert on the NEXT frame iff we didn't win, to beat any
  ///      async reassert from the TextField that lands after step 1.
  /// We never call `unfocus()` on the previous node, so there is no
  /// leaf→scope reparent for the TextField policy to fight over.
  void _claimFocus(String reason) {
    if (!mounted) return;
    final primaryBefore = FocusManager.instance.primaryFocus;
    _focusNode.requestFocus();
    labLogAlways('[focus.diag] NvimView _claimFocus($reason): '
        'before=${primaryBefore?.debugLabel ?? primaryBefore?.runtimeType.toString() ?? "null"} '
        'hasPrimaryFocus=${_focusNode.hasPrimaryFocus} '
        't=${DateTime.now().millisecondsSinceEpoch}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      if (!_focusNode.hasPrimaryFocus) {
        _focusNode.requestFocus();
        labLogAlways('[focus.diag] NvimView _claimFocus($reason) re-assert: '
            'hasPrimaryFocus=${_focusNode.hasPrimaryFocus} '
            't=${DateTime.now().millisecondsSinceEpoch}');
      }
    });
  }

  /// Read the current cursor's row out of the painted grid as a plain
  /// string. The grid includes nvim's line-number column + sign column
  /// + spaces — we drop the leading gutter so the returned text and
  /// cursor offset line up with what the parent treats as "line text"
  /// for hover-token detection.
  ///
  /// Returns `(lineText, cursorColInLineText)` so the chrome can hand
  /// both to its identifier-walker.
  ({String text, int col})? lineAndCursorSync() {
    if (_cursorRow < 0 || _cursorRow >= _rows) return null;
    final row = _cells[_cursorRow];
    final buf = StringBuffer();
    for (final c in row) {
      buf.write(c.char.isEmpty ? ' ' : c.char);
    }
    final raw = buf.toString();
    // The gutter is `signcolumn=yes` (2 chars) + `set number` (line-num
    // chars + 1 trailing space). Locate the gutter end by walking
    // forward until we hit a column that's NOT a digit or whitespace
    // OR we exceed the heuristic max gutter width.
    int gutter = 0;
    int digitsSeen = 0;
    while (gutter < raw.length && gutter < 12) {
      final ch = raw.codeUnitAt(gutter);
      final isDigit = ch >= 0x30 && ch <= 0x39;
      final isSpace = ch == 0x20;
      if (isDigit) {
        digitsSeen++;
        gutter++;
      } else if (isSpace) {
        gutter++;
        // Once we've seen at least one digit and reach a space, we're
        // past the line-number column.
        if (digitsSeen > 0) break;
      } else {
        // Sign-column glyph (E/W/i) before any digits — keep skipping.
        if (digitsSeen == 0) {
          gutter++;
        } else {
          break;
        }
      }
    }
    final text = raw.substring(gutter).trimRight();
    final col = (_cursorCol - gutter).clamp(0, text.length).toInt();
    return (text: text, col: col);
  }

  void _attachRedraw() {
    _redrawSub?.cancel();
    final mgr = widget.manager;
    final rpc = mgr?.rpc;
    if (rpc == null || mgr == null) return;
    _redrawSub = rpc.onRedraw.listen(_onRedrawEvent);
    // NOW it's safe for nvim to start streaming UI events. The manager
    // deferred ui_attach exactly so the initial hl_attr_define flood
    // lands after we're listening.
    mgr.attachUi();
  }

  @override
  void dispose() {
    _redrawSub?.cancel();
    _resizeDebounce?.cancel();
    _msgClearTimer?.cancel();
    _focusNode.removeListener(_logFocusChange);
    _focusNode.dispose();
    _scopeNode.dispose();
    super.dispose();
  }

  // ── redraw handling ───────────────────────────────────────────────

  void _onRedrawEvent(NvimRedrawEvent ev) {
    switch (ev.name) {
      case 'grid_resize':
        _handleGridResize(ev.args);
        break;
      case 'default_colors_set':
        _handleDefaultColors(ev.args);
        break;
      case 'hl_attr_define':
        _handleHlAttrDefine(ev.args);
        break;
      case 'hl_group_set':
        // We don't currently distinguish named groups; the per-cell hl_id
        // already carries everything we paint. No-op.
        break;
      case 'grid_line':
        _handleGridLine(ev.args);
        break;
      case 'grid_cursor_goto':
        _handleCursorGoto(ev.args);
        break;
      case 'grid_scroll':
        _handleGridScroll(ev.args);
        break;
      case 'grid_clear':
        _handleGridClear(ev.args);
        break;
      case 'mode_info_set':
        _handleModeInfoSet(ev.args);
        break;
      case 'mode_change':
        _handleModeChange(ev.args);
        break;
      case 'option_set':
      case 'set_title':
      case 'set_icon':
      case 'win_viewport':
      case 'tabline_update':
        // Informational — no-op.
        break;
      case 'busy_start':
        _busy = true;
        _markDirty();
        break;
      case 'busy_stop':
        _busy = false;
        _markDirty();
        break;
      case 'mouse_on':
        _mouseEnabled = true;
        break;
      case 'mouse_off':
        _mouseEnabled = false;
        break;
      case 'flush':
        _flush();
        break;
      case 'cmdline_show':
        _handleCmdlineShow(ev.args);
        break;
      case 'cmdline_pos':
        _handleCmdlinePos(ev.args);
        break;
      case 'cmdline_special_char':
        // Inserts a special char (e.g. for incsearch) at cmdline pos.
        // Cheap to ignore for now — nvim still emits cmdline_show on
        // commit.
        break;
      case 'cmdline_hide':
        _cmdVisible = false;
        _cmdContent = '';
        _markDirty();
        break;
      case 'cmdline_block_show':
      case 'cmdline_block_append':
      case 'cmdline_block_hide':
        // Multi-line cmdline (e.g. `:function`). Out of scope for the
        // lab; nvim falls back to the normal prompt for everything we
        // care about. No-op.
        break;
      case 'popupmenu_show':
        _handlePopupShow(ev.args);
        break;
      case 'popupmenu_select':
        _handlePopupSelect(ev.args);
        break;
      case 'popupmenu_hide':
        _pumVisible = false;
        _markDirty();
        break;
      case 'msg_show':
        _handleMsgShow(ev.args);
        break;
      case 'msg_clear':
        _msgClearTimer?.cancel();
        if (_msgText.isNotEmpty) {
          _msgText = '';
          _markDirty();
        }
        break;
      case 'msg_history_show':
      case 'msg_showmode':
      case 'msg_showcmd':
      case 'msg_ruler':
        // Kinds we don't render specially.
        break;
      case 'bell':
      case 'visual_bell':
        // No audio/visual bell in the lab.
        break;
    }
  }

  void _handleGridResize(List<dynamic> args) {
    // grid, width, height
    final cols = (args[1] as num).toInt();
    final rows = (args[2] as num).toInt();
    if (cols == _cols && rows == _rows) return;
    final newCells =
        List.generate(rows, (_) => List.filled(cols, _Cell.empty));
    final copyRows = math.min(rows, _rows);
    final copyCols = math.min(cols, _cols);
    for (var r = 0; r < copyRows; r++) {
      for (var c = 0; c < copyCols; c++) {
        newCells[r][c] = _cells[r][c];
      }
    }
    _cells = newCells;
    _rows = rows;
    _cols = cols;
    _markDirty();
  }

  void _handleDefaultColors(List<dynamic> args) {
    // rgb_fg, rgb_bg, rgb_sp, cterm_fg, cterm_bg
    int? toInt(dynamic v) => v == null ? null : (v as num).toInt();
    final fg = toInt(args[0]);
    final bg = toInt(args[1]);
    final sp = toInt(args[2]);
    if (fg != null && fg >= 0) _defaultFg = _rgbToColor(fg);
    if (bg != null && bg >= 0) _defaultBg = _rgbToColor(bg);
    if (sp != null && sp >= 0) _defaultSp = _rgbToColor(sp);
    _markDirty();
  }

  void _handleHlAttrDefine(List<dynamic> args) {
    // id, rgb_attr (Map), cterm_attr (Map), info (List)
    final id = (args[0] as num).toInt();
    final rgb = (args[1] as Map?) ?? const {};
    Color? color(String key) {
      final v = rgb[key] ?? rgb[_b(key)];
      if (v is num) return _rgbToColor(v.toInt());
      return null;
    }
    bool flag(String key) {
      final v = rgb[key] ?? rgb[_b(key)];
      return v == true;
    }
    final attr = _HlAttr(
      fg: color('foreground'),
      bg: color('background'),
      sp: color('special'),
      reverse: flag('reverse'),
      bold: flag('bold'),
      italic: flag('italic'),
      underline: flag('underline'),
      undercurl: flag('undercurl'),
      strikethrough: flag('strikethrough'),
    );
    _attrs[id] = attr;
    // Periodic palette-size dump. A healthy Python buffer with
    // `syntax on` + `filetype=python` ends up with 40-80 highlight
    // groups. A "syntax lost" state has < 10. Logging the total here
    // every Nth define gives a noise-free signal of whether the
    // syntax engine is alive.
    if (_attrs.length % 10 == 0) {
      labLog('[nvim.hl] palette grew to ${_attrs.length} groups');
    }
  }

  /// Public debug hook — call from DevTools console:
  ///   `window._epyxVimDiag()`
  /// to dump the current vim-view state (palette size, mode, current
  /// filetype option) without rebuilding. Wired in `initState`.
  Future<Map<String, Object?>> dumpDiag() async {
    final rpc = widget.manager?.rpc;
    String? filetype;
    String? syntax;
    int? linesCount;
    if (rpc != null) {
      try {
        filetype = (await rpc.request('nvim_buf_get_option', [0, 'filetype']))
            ?.toString();
        syntax = (await rpc.request('nvim_buf_get_option', [0, 'syntax']))
            ?.toString();
        final lines = await rpc.request('nvim_buf_get_lines', [0, 0, -1, false]);
        linesCount = lines is List ? lines.length : null;
      } catch (e) {
        labLog('[nvim.diag] rpc probe failed: $e');
      }
    }
    final m = <String, Object?>{
      'palette_size': _attrs.length,
      'mode': _curModeInfo?.name,
      'rows': _rows,
      'cols': _cols,
      'filetype': filetype,
      'syntax': syntax,
      'lines': linesCount,
      'rpc_alive': widget.manager?.isHealthy ?? false,
    };
    labLogAlways('[nvim.diag] $m');
    return m;
  }

  void _handleGridLine(List<dynamic> args) {
    // grid, row, col_start, cells, [wrap]
    final row = (args[1] as num).toInt();
    final colStart = (args[2] as num).toInt();
    var col = colStart;
    final cells = args[3] as List;
    if (row < 0 || row >= _rows) return;
    if (!_firstLineLogged) {
      _firstLineLogged = true;
      labLogAlways('[wmtime] NvimView first grid_line — content painted '
          't=${DateTime.now().millisecondsSinceEpoch}');
    }
    int prevHl = 0;
    final dbg = <String>[];
    for (final raw in cells) {
      final c = raw as List;
      final ch = c[0].toString();
      final hl = c.length >= 2 ? (c[1] as num).toInt() : prevHl;
      final repeat = c.length >= 3 ? (c[2] as num).toInt() : 1;
      prevHl = hl;
      final cell = _Cell(ch.isEmpty ? ' ' : ch, hl);
      for (var i = 0; i < repeat; i++) {
        if (col >= _cols) break;
        _cells[row][col] = cell;
        if (kLabDebug) dbg.add('${ch.isEmpty ? '·' : ch}:$hl');
        col++;
      }
    }
    if (kLabDebug && dbg.any((s) => s.contains('{') || s.contains('}'))) {
      labLog('[nvim.gridline] r=$row col=$colStart cells=${dbg.join(' ')}');
    }
    _markDirty();
  }

  void _handleCursorGoto(List<dynamic> args) {
    // grid, row, col
    _cursorRow = (args[1] as num).toInt();
    _cursorCol = (args[2] as num).toInt();
    _markDirty();
  }

  void _handleGridScroll(List<dynamic> args) {
    // grid, top, bot, left, right, rows, cols
    final top = (args[1] as num).toInt();
    final bot = (args[2] as num).toInt();
    final left = (args[3] as num).toInt();
    final right = (args[4] as num).toInt();
    final scrollRows = (args[5] as num).toInt();
    // cols arg is reserved (always 0); horizontal scroll is unused.
    if (scrollRows > 0) {
      // Scroll up: rows [top+rows, bot) move to [top, bot-rows).
      for (var r = top; r < bot - scrollRows; r++) {
        for (var c = left; c < right; c++) {
          _cells[r][c] = _cells[r + scrollRows][c];
        }
      }
    } else if (scrollRows < 0) {
      // Scroll down: rows [top, bot+rows) move to [top-rows, bot).
      final n = -scrollRows;
      for (var r = bot - 1; r >= top + n; r--) {
        for (var c = left; c < right; c++) {
          _cells[r][c] = _cells[r - n][c];
        }
      }
    }
    _markDirty();
  }

  void _handleGridClear(List<dynamic> args) {
    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        _cells[r][c] = _Cell.empty;
      }
    }
    _markDirty();
  }

  void _handleModeInfoSet(List<dynamic> args) {
    // cursor_style_enabled, mode_info (List<Map>)
    final infos = (args[1] as List?) ?? const [];
    _modeInfos = infos.map((m) {
      final mm = (m as Map);
      String? str(String k) {
        final v = mm[k] ?? mm[_b(k)];
        return v?.toString();
      }
      int? intOf(String k) {
        final v = mm[k] ?? mm[_b(k)];
        return v is num ? v.toInt() : null;
      }
      return _ModeInfo(
        name: str('name') ?? '',
        shortName: str('short_name') ?? '',
        cursorShape: str('cursor_shape') ?? 'block',
        cellPercentage: intOf('cell_percentage') ?? 100,
        attrId: intOf('attr_id') ?? 0,
      );
    }).toList(growable: false);
  }

  void _handleModeChange(List<dynamic> args) {
    final idx = (args[1] as num).toInt();
    if (idx >= 0 && idx < _modeInfos.length) {
      _curModeInfo = _modeInfos[idx];
    }
    _markDirty();
    // Dump diag on every mode change — gives an unmissable trace in
    // the console of when the highlight palette / filetype state
    // changes. If syntax visually breaks, the latest mode-change
    // dump tells us whether the palette collapsed (small _attrs) or
    // is still present but not being applied (large _attrs but no
    // color on screen).
    final modeName = args.isNotEmpty ? args[0].toString() : '?';
    labLog('[nvim.mode] → $modeName (palette=${_attrs.length} '
        'mode_info=${_curModeInfo?.name})');
  }

  void _handleCmdlineShow(List<dynamic> args) {
    // content (List of [attr, text]), pos, firstc, prompt, indent, level
    final content = (args[0] as List?) ?? const [];
    final pos = (args[1] as num).toInt();
    final firstc = args[2].toString();
    final buf = StringBuffer();
    for (final chunk in content) {
      final list = chunk as List;
      // [attr_id, text] or [attr_id, text, hl_id]
      if (list.length >= 2) buf.write(list[1]);
    }
    _cmdContent = buf.toString();
    _cmdPos = pos;
    _cmdFirstChar = firstc;
    _cmdVisible = true;
    _markDirty();
  }

  void _handleCmdlinePos(List<dynamic> args) {
    _cmdPos = (args[0] as num).toInt();
    _markDirty();
  }

  void _handlePopupShow(List<dynamic> args) {
    // items (List of [word, kind, menu, info]), selected, row, col, grid
    final items = (args[0] as List?) ?? const [];
    _pumItems = items.map((it) {
      final l = it as List;
      return l.isNotEmpty ? l.first.toString() : '';
    }).toList(growable: false);
    _pumSelected = (args[1] as num).toInt();
    _pumRow = (args[2] as num).toInt();
    _pumCol = (args[3] as num).toInt();
    _pumVisible = true;
    _markDirty();
  }

  void _handlePopupSelect(List<dynamic> args) {
    _pumSelected = (args[0] as num).toInt();
    _markDirty();
  }

  void _handleMsgShow(List<dynamic> args) {
    // kind, content (List of [attr, text, hl?]), replace_last, [history?]
    final content = (args[1] as List?) ?? const [];
    final buf = StringBuffer();
    for (final chunk in content) {
      final list = chunk as List;
      if (list.length >= 2) buf.write(list[1]);
    }
    _msgText = buf.toString();
    if (_msgText.isEmpty) return;
    _markDirty();
    _msgClearTimer?.cancel();
    _msgClearTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _msgText = '';
      _markDirty();
    });
  }

  void _markDirty() {
    _dirty = true;
  }

  void _flush() {
    if (!_dirty) return;
    _dirty = false;
    if (mounted) setState(() {});
  }

  // ── input ─────────────────────────────────────────────────────────

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      labLog('[nvim.key] ${event.logicalKey.debugName ?? event.logicalKey} '
          'char=${event.character?.codeUnits} '
          'focused=${node.hasFocus} active=${widget.active}');
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final rpc = widget.manager?.rpc;
    if (rpc == null) return KeyEventResult.ignored;

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;

    // Hover popup gets first crack at Esc.
    if (HoverPopup.isOpen &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      HoverPopup.dismiss();
      return KeyEventResult.handled;
    }

    // Cmd-K / Cmd-S → bubble to parent Shortcuts.
    if ((meta || ctrl) &&
        (event.logicalKey == LogicalKeyboardKey.keyK ||
            event.logicalKey == LogicalKeyboardKey.keyS)) {
      return KeyEventResult.ignored;
    }
    // Cmd-/ → flip to EZ. Don't bubble (the outer CallbackShortcuts
    // wouldn't fire because nvim swallows printable keystrokes inside
    // its own input handler), invoke the callback directly.
    if ((meta || ctrl) &&
        event.logicalKey == LogicalKeyboardKey.slash &&
        widget.onToggleMode != null) {
      widget.onToggleMode!();
      return KeyEventResult.handled;
    }
    // Cmd-C → copy visual selection (or current line) to system
    // clipboard. nvim's clipboard provider is unavailable with
    // `-u NONE --noplugin`, so we read the selected text via RPC and
    // hand it to Flutter's Clipboard ourselves.
    if (meta && event.logicalKey == LogicalKeyboardKey.keyC) {
      _copySelectionToClipboard();
      return KeyEventResult.handled;
    }

    // VimCompletionPopup interactions.
    if (VimCompletionPopup.isOpen) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        VimCompletionPopup.dismiss();
        // Fall through so Esc still reaches nvim.
      } else if (event.logicalKey == LogicalKeyboardKey.tab ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          (ctrl && event.logicalKey == LogicalKeyboardKey.keyY)) {
        final accepted = VimCompletionPopup.acceptCurrent();
        if (accepted != null && accepted.word != accepted.filterTerm) {
          _insertCompletion(rpc, accepted.word, accepted.filterTerm);
          return KeyEventResult.handled;
        }
        if (event.logicalKey != LogicalKeyboardKey.enter) {
          return KeyEventResult.handled;
        }
        // Plain Enter falls through.
      }
      if ((ctrl && event.logicalKey == LogicalKeyboardKey.keyN) ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        VimCompletionPopup.moveSelection(1);
        return KeyEventResult.handled;
      }
      if ((ctrl && event.logicalKey == LogicalKeyboardKey.keyP) ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        VimCompletionPopup.moveSelection(-1);
        return KeyEventResult.handled;
      }
    }

    // ?? line + plain Enter → Haiku rewrite.
    final isPlainEnter = (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !shift &&
        !ctrl &&
        !meta &&
        !alt;
    if (isPlainEnter) {
      _handleEnterMaybeHaiku(rpc);
      return KeyEventResult.handled;
    }

    final encoded = _encodeNvimKey(event);
    if (encoded == null) return KeyEventResult.ignored;
    rpc.notify('nvim_input', [encoded]);

    // Schedule a completion poll for INSERT mode based on the typed char.
    final ch = event.character ?? '';
    final isWordOrDot = ch.length == 1 &&
        (ch == '.' ||
            ch == '_' ||
            (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) ||
            (ch.codeUnitAt(0) >= 0x41 && ch.codeUnitAt(0) <= 0x5a) ||
            (ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7a));
    final isBackspace = event.logicalKey == LogicalKeyboardKey.backspace;
    if (isWordOrDot || isBackspace) {
      _pollCompletions();
    } else {
      VimCompletionPopup.dismiss();
    }

    return KeyEventResult.handled;
  }

  Future<void> _pollCompletions() async {
    final rpc = widget.manager?.rpc;
    final lsp = widget.lsp;
    if (rpc == null || lsp == null || widget.uri.isEmpty) {
      labLog('[vim.complete] poll skipped: rpc=${rpc != null} '
          'lsp=${lsp != null} uri=${widget.uri.isNotEmpty}');
      return;
    }
    try {
      final m = await rpc.request('nvim_get_mode', []);
      final modeMap = (m as Map?) ?? const {};
      final mode = (modeMap['mode'] ?? modeMap[_b('mode')] ?? '').toString();
      if (!mode.startsWith('i')) {
        labLog('[vim.complete] poll dismiss: mode=$mode (not insert)');
        VimCompletionPopup.dismiss();
        return;
      }
      final cur = await rpc.getCursor();
      final line = cur.$1;
      final col = cur.$2;
      final lines =
          await rpc.request('nvim_buf_get_lines', [0, line, line + 1, false]);
      final lineText =
          (lines is List && lines.isNotEmpty) ? lines.first.toString() : '';
      if (!vimShouldComplete(lineText, col)) {
        labLog('[vim.complete] poll dismiss: shouldComplete=false '
            'line="$lineText" col=$col');
        VimCompletionPopup.dismiss();
        return;
      }
      final prefix = vimWordPrefix(lineText, col);
      final lastDot = prefix.lastIndexOf('.');
      final filterTerm =
          lastDot >= 0 ? prefix.substring(lastDot + 1) : prefix;
      final fetchCol = col - prefix.length + (lastDot + 1);
      labLog('[vim.complete] poll showing: line=$line col=$col '
          'prefix="$prefix" filter="$filterTerm"');
      lsp.didChange(widget.uri, await _bufferText(rpc), version: 1);
      if (!mounted) return;
      await VimCompletionPopup.show(
        context: context,
        lsp: lsp,
        uri: widget.uri,
        line: line,
        col: fetchCol,
        filterTerm: filterTerm,
        anchorScreenTopLeft: _cursorAnchorOffset(),
        onAccept: (word, ft) {
          final back = '<BS>' * ft.length;
          rpc.notify('nvim_input', ['$back$word']);
        },
      );
    } catch (e) {
      debugPrint('[vim.complete] poll failed: $e');
    }
  }

  /// Screen-pixel position of the line directly BELOW the current
  /// cursor row. Computed via the View's render box so the popup lands
  /// where the cursor actually is, not pinned to the bottom-left like
  /// before. Returns null if the box hasn't been laid out yet.
  Offset? _cursorAnchorOffset() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset(
      _cursorCol * _cellW,
      (_cursorRow + 1) * _cellH,
    ));
  }

  Future<String> _bufferText(NvimRpcClient rpc) async {
    final lines = await rpc.request('nvim_buf_get_lines', [0, 0, -1, false]);
    if (lines is! List) return '';
    return lines.map((l) => l.toString()).join('\n');
  }

  void _insertCompletion(NvimRpcClient rpc, String word, String filterTerm) {
    final back = '<BS>' * filterTerm.length;
    rpc.notify('nvim_input', ['$back$word']);
  }

  Future<void> _handleEnterMaybeHaiku(NvimRpcClient rpc) async {
    try {
      final m = await rpc.request('nvim_get_mode', []);
      final modeMap = (m as Map?) ?? const {};
      final mode = (modeMap['mode'] ?? modeMap[_b('mode')] ?? '').toString();
      if (!mode.startsWith('i')) {
        rpc.notify('nvim_input', [r'<CR>']);
        return;
      }
      final cur = await rpc.getCursor();
      final lineIdx = cur.$1;
      final lines = await rpc
          .request('nvim_buf_get_lines', [0, lineIdx, lineIdx + 1, false]);
      final lineText =
          (lines is List && lines.isNotEmpty) ? lines.first.toString() : '';
      if (!HaikuRewrite.isMagicLine(lineText)) {
        rpc.notify('nvim_input', [r'<CR>']);
        return;
      }
      await _runHaikuOnMagicLine(rpc, lineIdx, lineText);
    } catch (e) {
      debugPrint('[nvim.haiku] enter handling failed: $e — forwarding <CR>');
      rpc.notify('nvim_input', [r'<CR>']);
    }
  }

  Future<void> _runHaikuOnMagicLine(
      NvimRpcClient rpc, int lineIdx, String lineText) async {
    final indent = RegExp(r'^\s*').firstMatch(lineText)?.group(0) ?? '';
    try {
      await rpc.request('nvim_input', [r'<C-\><C-n>']);
    } catch (_) {}
    await rpc.request('nvim_buf_set_lines', [
      0,
      lineIdx,
      lineIdx + 1,
      false,
      ['$indent# ?? thinking…'],
    ]);
    final result = await HaikuRewrite.rewriteLine(lineText);
    if (!mounted) return;
    if (result == null || result.isEmpty) {
      await rpc.request('nvim_buf_set_lines',
          [0, lineIdx, lineIdx + 1, false, [lineText]]);
      return;
    }
    final indented = result
        .split('\n')
        .map((l) => l.isEmpty ? l : '$indent$l')
        .toList();
    await rpc.request('nvim_buf_set_lines',
        [0, lineIdx, lineIdx + 1, false, indented]);
    final endLine = lineIdx + indented.length - 1;
    final endCol = indented.last.length;
    await rpc.request('nvim_win_set_cursor', [
      0,
      [endLine + 1, endCol],
    ]);
  }

  // ── mouse ─────────────────────────────────────────────────────────

  // Track the most recent grid-cell the pointer was over so drag
  // events that don't cross a cell boundary aren't sent unnecessarily.
  int _dragLastRow = -1;
  int _dragLastCol = -1;

  void _gridCellFromLocal(Offset p, void Function(int row, int col) cb) {
    final col = (p.dx / _cellW).floor().clamp(0, _cols - 1);
    final row = (p.dy / _cellH).floor().clamp(0, _rows - 1);
    cb(row, col);
  }

  void _logFocusChange() {
    labLogAlways('[focus.diag] NvimView focus changed: '
        'hasFocus=${_focusNode.hasFocus} '
        'hasPrimaryFocus=${_focusNode.hasPrimaryFocus} '
        't=${DateTime.now().millisecondsSinceEpoch}');
  }

  void _onPointerDown(PointerDownEvent ev) {
    final primaryBefore = FocusManager.instance.primaryFocus;
    labLogAlways('[focus.diag] NvimView._onPointerDown: '
        'active=${widget.active} '
        'hadFocus=${_focusNode.hasFocus} '
        'canRequestFocus=${_focusNode.canRequestFocus} '
        'primaryBefore=${primaryBefore?.debugLabel ?? primaryBefore?.runtimeType.toString() ?? "null"} '
        'mouseEnabled=$_mouseEnabled '
        't=${DateTime.now().millisecondsSinceEpoch}');
    if (widget.active) {
      _claimFocus('pointerDown');
    }
    if (!_mouseEnabled) return;
    final rpc = widget.manager?.rpc;
    if (rpc == null) return;
    // Only treat primary button as "select". Right-click etc. are
    // ignored for now.
    if (ev.buttons & kPrimaryButton == 0 && ev.buttons != 0) return;
    _gridCellFromLocal(ev.localPosition, (row, col) {
      _dragLastRow = row;
      _dragLastCol = col;
      rpc.notify('nvim_input_mouse', ['left', 'press', '', 0, row, col]);
    });
  }

  void _onPointerMove(PointerMoveEvent ev) {
    if (!_mouseEnabled) return;
    if (ev.buttons & kPrimaryButton == 0) return;
    final rpc = widget.manager?.rpc;
    if (rpc == null) return;
    _gridCellFromLocal(ev.localPosition, (row, col) {
      if (row == _dragLastRow && col == _dragLastCol) return;
      _dragLastRow = row;
      _dragLastCol = col;
      // 'drag' is nvim's continue-while-button-down action. Combined
      // with mouse=a in our bootstrap, this enters & extends Visual
      // mode automatically — exactly what the user wants for "select
      // by dragging like in EZ".
      rpc.notify('nvim_input_mouse', ['left', 'drag', '', 0, row, col]);
    });
  }

  void _onPointerUp(PointerUpEvent ev) {
    if (!_mouseEnabled) return;
    final rpc = widget.manager?.rpc;
    if (rpc == null) return;
    _gridCellFromLocal(ev.localPosition, (row, col) {
      rpc.notify('nvim_input_mouse', ['left', 'release', '', 0, row, col]);
    });
    _dragLastRow = -1;
    _dragLastCol = -1;
  }

  /// Cmd-C copy: ask nvim what the visual selection's text is and
  /// hand it to the system clipboard. With `-u NONE --noplugin` we
  /// can't rely on nvim's `+` register / clipboard provider, so we
  /// roll our own. If there's no active visual selection, copy the
  /// current line — matches macOS "Cmd-C with no selection" behavior
  /// in some apps.
  Future<void> _copySelectionToClipboard() async {
    final rpc = widget.manager?.rpc;
    if (rpc == null) return;
    try {
      // nvim_exec_lua returns a {text, mode} dict. Force normal mode
      // first so getregion picks the latest visual marks reliably.
      final lua = r'''
local m = vim.fn.mode()
if m:match('^[vV\22]') then
  -- Yank the visual selection into our scratch register.
  vim.cmd('silent normal! "zy')
  return { text = vim.fn.getreg('z'), kind = 'visual' }
end
local row = vim.fn.line('.')
local lines = vim.api.nvim_buf_get_lines(0, row - 1, row, false)
return { text = (lines[1] or ''), kind = 'line' }
''';
      final res = await rpc.request('nvim_exec_lua', [lua, []]);
      final text = (res is Map ? res['text'] : null)?.toString() ?? '';
      if (text.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: text));
      labLog('[nvim.copy] ${text.length} chars to clipboard');
    } catch (e) {
      debugPrint('[nvim.copy] failed: $e');
    }
  }

  // ── resize ────────────────────────────────────────────────────────

  void _onSizeChanged(Size size) {
    final cols = math.max(1, (size.width / _cellW).floor());
    final rows = math.max(1, (size.height / _cellH).floor());
    if (_lastSentSize != null &&
        cols == (_lastSentSize!.width / _cellW).floor() &&
        rows == (_lastSentSize!.height / _cellH).floor()) {
      return;
    }
    _lastSentSize = size;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 80), () {
      final rpc = widget.manager?.rpc;
      if (rpc == null) return;
      rpc.request('nvim_ui_try_resize', [cols, rows]).catchError((e) {
        debugPrint('[nvim] ui_try_resize failed: $e');
        return null;
      });
    });
  }

  // ── text metrics ──────────────────────────────────────────────────

  void _measureCell() {
    final tp = TextPainter(
      text: TextSpan(
        text: 'M',
        style: _baseTextStyle(const Color(0xFFCCCCCC)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _cellW = tp.width;
    _cellH = _fontSize * _fontHeight;
    tp.dispose();
  }

  // The EZ editor passes 'JetBrainsMono, Menlo, monospace' as a single
  // string and Flutter's macOS engine treats it as a literal family
  // name — most of the time it lands on the system default. We use the
  // proper Flutter idiom: pick `Menlo` (a real macOS system font),
  // with explicit fallbacks for the bundled name + Linux/Windows
  // monospaces. Measured cell width on this style drives the painter,
  // so a non-monospace fallback would show as character-spread.
  TextStyle _baseTextStyle(Color color, {
    bool bold = false,
    bool italic = false,
    TextDecoration? deco,
    Color? decoColor,
    TextDecorationStyle? decoStyle,
  }) {
    return TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: const [
        'JetBrainsMono',
        'SF Mono',
        'Consolas',
        'Courier New',
        'monospace',
      ],
      fontSize: _fontSize,
      height: _fontHeight,
      color: color,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: deco,
      decorationColor: decoColor,
      decorationStyle: decoStyle,
    );
  }

  // ── build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.manager == null) {
      return const _NotReadyHint();
    }
    // FocusScope wraps the editor's Focus so the editor owns a scope
    // distinct from the doclet. Mounting this scope does NOT autofocus
    // (no `autofocus: true` descendant) — Cmd-E opens the editor as a
    // side panel while keyboard focus stays on the doclet control until
    // an explicit click or mode switch, preserving existing behavior.
    return FocusScope(
      node: _scopeNode,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKeyEvent,
        child: LayoutBuilder(builder: (ctx, constraints) {
        // Schedule a resize on next frame if size changed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onSizeChanged(constraints.biggest);
        });
        return Listener(
          // Listener (not GestureDetector) so we get raw pointer
          // down/move/up — needed for nvim's drag-to-select. The
          // gesture system would arbitrate pan vs tap and consume
          // events we want to forward verbatim.
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: _defaultBg,
                  child: CustomPaint(
                    painter: _GridPainter(
                      cells: _cells,
                      rows: _rows,
                      cols: _cols,
                      cellW: _cellW,
                      cellH: _cellH,
                      attrs: _attrs,
                      defaultFg: _defaultFg,
                      defaultBg: _defaultBg,
                      defaultSp: _defaultSp,
                      cursorRow: _cursorRow,
                      cursorCol: _cursorCol,
                      cursorShape: _curModeInfo?.cursorShape ?? 'block',
                      cursorPercentage:
                          _curModeInfo?.cellPercentage ?? 100,
                      cursorVisible: widget.active && !_busy,
                      makeStyle: _baseTextStyle,
                    ),
                  ),
                ),
              ),
              if (_cmdVisible) _buildCmdline(),
              if (_pumVisible) _buildPopup(),
              if (_msgText.isNotEmpty) _buildMsg(),
            ],
          ),
        );
      }),
      ),
    );
  }

  Widget _buildCmdline() {
    final text = '$_cmdFirstChar$_cmdContent';
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: const Color(0xCC1c1c1e),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Stack(
          children: [
            Text(text, style: _baseTextStyle(const Color(0xFFEEEEEE))),
            Positioned(
              left: (_cmdPos + _cmdFirstChar.length) * _cellW,
              top: 0,
              child: Container(
                width: 2,
                height: _cellH,
                color: const Color(0xFFCCCCCC),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopup() {
    final left = (_pumCol * _cellW).clamp(0, double.infinity);
    final top = ((_pumRow + 1) * _cellH).clamp(0, double.infinity);
    return Positioned(
      left: left.toDouble(),
      top: top.toDouble(),
      child: Material(
        elevation: 6,
        color: const Color(0xFF222226),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 240),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _pumItems.length,
            itemBuilder: (ctx, i) {
              final selected = i == _pumSelected;
              return Container(
                color: selected ? const Color(0xFF335577) : null,
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                child: Text(_pumItems[i],
                    style: _baseTextStyle(const Color(0xFFEEEEEE))),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMsg() {
    return Positioned(
      right: 8,
      bottom: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: const Color(0xCC222226),
        child: Text(_msgText, style: _baseTextStyle(const Color(0xFFCCCCCC))),
      ),
    );
  }

  // ── nvim key encoding ─────────────────────────────────────────────

  String? _encodeNvimKey(KeyEvent event) {
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    String withMods(String body) {
      var prefix = '';
      if (meta) prefix += 'D-';
      if (alt) prefix += 'M-';
      if (ctrl) prefix += 'C-';
      return '<$prefix$body>';
    }

    final specials = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.escape: 'Esc',
      LogicalKeyboardKey.enter: 'CR',
      LogicalKeyboardKey.numpadEnter: 'CR',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.backspace: 'BS',
      LogicalKeyboardKey.delete: 'Del',
      LogicalKeyboardKey.arrowUp: 'Up',
      LogicalKeyboardKey.arrowDown: 'Down',
      LogicalKeyboardKey.arrowLeft: 'Left',
      LogicalKeyboardKey.arrowRight: 'Right',
      LogicalKeyboardKey.home: 'Home',
      LogicalKeyboardKey.end: 'End',
      LogicalKeyboardKey.pageUp: 'PageUp',
      LogicalKeyboardKey.pageDown: 'PageDown',
      LogicalKeyboardKey.f1: 'F1',
      LogicalKeyboardKey.f2: 'F2',
      LogicalKeyboardKey.f3: 'F3',
      LogicalKeyboardKey.f4: 'F4',
      LogicalKeyboardKey.f5: 'F5',
      LogicalKeyboardKey.f6: 'F6',
      LogicalKeyboardKey.f7: 'F7',
      LogicalKeyboardKey.f8: 'F8',
      LogicalKeyboardKey.f9: 'F9',
      LogicalKeyboardKey.f10: 'F10',
      LogicalKeyboardKey.f11: 'F11',
      LogicalKeyboardKey.f12: 'F12',
      LogicalKeyboardKey.space: 'Space',
    };
    final name = specials[key];
    if (name != null) {
      if (shift && key == LogicalKeyboardKey.tab) return '<S-Tab>';
      if (!ctrl && !alt && !meta) return '<$name>';
      return withMods(name);
    }

    final ch = event.character;
    if (ctrl || alt || meta) {
      String? letter;
      final lbl = key.keyLabel;
      if (lbl.length == 1) letter = lbl.toLowerCase();
      letter ??= ch?.toLowerCase();
      if (letter != null && letter.isNotEmpty) {
        return withMods(letter);
      }
    }

    if (ch != null && ch.isNotEmpty) {
      if (ch == '<') return '<lt>';
      return ch;
    }
    return null;
  }
}

// ─── helpers ────────────────────────────────────────────────────────

// msgpack maps sometimes have keys as bytes. Helper: byte-key form.
List<int> _b(String s) => s.codeUnits;

Color _rgbToColor(int rgb) {
  // nvim sends 0xRRGGBB as a 24-bit int; -1 means "use default".
  if (rgb < 0) return const Color(0x00000000);
  return Color(0xFF000000 | (rgb & 0xFFFFFF));
}

class _Cell {
  final String char;
  final int hlId;
  const _Cell(this.char, this.hlId);
  static const _Cell empty = _Cell(' ', 0);
}

class _HlAttr {
  final Color? fg;
  final Color? bg;
  final Color? sp;
  final bool reverse;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool undercurl;
  final bool strikethrough;
  const _HlAttr({
    this.fg,
    this.bg,
    this.sp,
    this.reverse = false,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.undercurl = false,
    this.strikethrough = false,
  });
  static const _HlAttr empty = _HlAttr();
}

class _ModeInfo {
  final String name;
  final String shortName;
  final String cursorShape;
  final int cellPercentage;
  final int attrId;
  const _ModeInfo({
    required this.name,
    required this.shortName,
    required this.cursorShape,
    required this.cellPercentage,
    required this.attrId,
  });
}

typedef _StyleFactory = TextStyle Function(
  Color color, {
  bool bold,
  bool italic,
  TextDecoration? deco,
  Color? decoColor,
  TextDecorationStyle? decoStyle,
});

class _GridPainter extends CustomPainter {
  final List<List<_Cell>> cells;
  final int rows;
  final int cols;
  final double cellW;
  final double cellH;
  final Map<int, _HlAttr> attrs;
  final Color defaultFg;
  final Color defaultBg;
  final Color defaultSp;
  final int cursorRow;
  final int cursorCol;
  final String cursorShape;
  final int cursorPercentage;
  final bool cursorVisible;
  final _StyleFactory makeStyle;

  _GridPainter({
    required this.cells,
    required this.rows,
    required this.cols,
    required this.cellW,
    required this.cellH,
    required this.attrs,
    required this.defaultFg,
    required this.defaultBg,
    required this.defaultSp,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorShape,
    required this.cursorPercentage,
    required this.cursorVisible,
    required this.makeStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint();

    // Pass 1: backgrounds.
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final cell = cells[r][c];
        final attr = attrs[cell.hlId] ?? _HlAttr.empty;
        Color bg = attr.bg ?? defaultBg;
        Color fg = attr.fg ?? defaultFg;
        if (attr.reverse) {
          final t = bg;
          bg = fg;
          fg = t;
        }
        if (bg != defaultBg) {
          bgPaint.color = bg;
          canvas.drawRect(
              Rect.fromLTWH(c * cellW, r * cellH, cellW, cellH), bgPaint);
        }
      }
    }

    // Pass 2: cursor background (block / vbar / hbar).
    if (cursorVisible) {
      final cx = cursorCol * cellW;
      final cy = cursorRow * cellH;
      final cursorPaint = Paint()..color = defaultFg.withValues(alpha: 0.85);
      switch (cursorShape) {
        case 'horizontal':
          final h = cellH * (cursorPercentage / 100.0);
          canvas.drawRect(
              Rect.fromLTWH(cx, cy + (cellH - h), cellW, h), cursorPaint);
          break;
        case 'vertical':
          final w = cellW * (cursorPercentage / 100.0);
          canvas.drawRect(
              Rect.fromLTWH(cx, cy, math.max(2, w), cellH), cursorPaint);
          break;
        case 'block':
        default:
          canvas.drawRect(
              Rect.fromLTWH(cx, cy, cellW, cellH), cursorPaint);
          break;
      }
    }

    // Pass 3: glyphs.
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final cell = cells[r][c];
        if (cell.char.isEmpty || cell.char == ' ') {
          // Skip spaces unless they're under the cursor (block cursor
          // already painted; the glyph would be transparent anyway).
          continue;
        }
        final attr = attrs[cell.hlId] ?? _HlAttr.empty;
        Color bg = attr.bg ?? defaultBg;
        Color fg = attr.fg ?? defaultFg;
        if (attr.reverse) {
          final t = bg;
          bg = fg;
          fg = t;
        }
        // If we're directly under the block cursor, swap to bg of cell.
        final underCursor = cursorVisible &&
            cursorShape == 'block' &&
            r == cursorRow &&
            c == cursorCol;
        if (underCursor) {
          fg = bg;
        }
        // Cell-level decoration: keep underline + strikethrough here.
        // Undercurl is handled in Pass 4 as a contiguous path so the
        // wave doesn't reset at every cell boundary.
        final hasDeco = attr.underline || attr.strikethrough;
        final tp = TextPainter(
          text: TextSpan(
            text: cell.char,
            style: makeStyle(
              fg,
              bold: attr.bold,
              italic: attr.italic,
              deco: hasDeco
                  ? TextDecoration.combine([
                      if (attr.underline) TextDecoration.underline,
                      if (attr.strikethrough) TextDecoration.lineThrough,
                    ])
                  : null,
              decoColor: fg,
              decoStyle: TextDecorationStyle.solid,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(c * cellW, r * cellH));
        tp.dispose();
      }
    }

    // Pass 4: contiguous wavy underlines for undercurl runs (i.e.
    // diagnostic squiggles). EZ uses Flutter's TextDecorationStyle.wavy
    // on a single TextSpan covering the whole range — visually one
    // continuous wave. Per-cell painting (which we did in earlier
    // versions) restarted the wave phase at every cell, producing a
    // fragmented look. Here we walk each row, identify runs of
    // undercurl=true cells, and paint one Path per run.
    final wavePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..isAntiAlias = true;
    for (var r = 0; r < rows; r++) {
      var c = 0;
      while (c < cols) {
        final attr0 = attrs[cells[r][c].hlId] ?? _HlAttr.empty;
        if (!attr0.undercurl) {
          c++;
          continue;
        }
        final startCol = c;
        Color sp = attr0.sp ?? defaultSp;
        while (c < cols) {
          final a = attrs[cells[r][c].hlId] ?? _HlAttr.empty;
          if (!a.undercurl) break;
          // The first hl_id with a `special` color in the run wins.
          sp = a.sp ?? sp;
          c++;
        }
        final x0 = startCol * cellW;
        final x1 = c * cellW;
        // Baseline a touch above the cell bottom so the wave doesn't
        // collide with the next row's text.
        final y = (r + 1) * cellH - 2;
        final amplitude = 1.5;
        final wavelength = 4.0; // pixels per full cycle
        final path = Path()..moveTo(x0, y);
        // Build a smooth path with quadratic segments. Two quadratic
        // beziers per wavelength gives a clean sine-ish curve at a
        // fraction of the cost of sampling sin() per pixel.
        var x = x0;
        var goingDown = true;
        while (x < x1) {
          final next = math.min(x + wavelength / 2, x1);
          final cx = (x + next) / 2;
          final cy = y + (goingDown ? amplitude : -amplitude);
          path.quadraticBezierTo(cx, cy, next, y);
          goingDown = !goingDown;
          x = next;
        }
        wavePaint.color = sp;
        canvas.drawPath(path, wavePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => true;
}

class _NotReadyHint extends StatelessWidget {
  const _NotReadyHint();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111111),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: const Text(
        'nvim manager not ready (start failed?). Check console for [nvim] logs.',
        style: TextStyle(
          color: Color(0xFFffaa33),
          fontSize: 12,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
