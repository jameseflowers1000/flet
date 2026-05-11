// Spawns `nvim --embed` once for the whole lab and exposes a msgpack-RPC
// client connected to its stdin/stdout. The renderer is `NvimEmbedView`
// (CustomPaint), which subscribes to redraw events and paints the grid
// natively in Flutter — there is NO WebView, NO ttyd, NO tmux, NO iframe.
//
// Architecture:
//   * Desktop (macOS/Linux/Windows): Process.start nvim --embed, bind
//     msgpack-RPC to stdin/stdout.
//   * Web (Chrome): connect to lab_chrome_proxy.py over WebSocket; the
//     proxy spawns its own nvim --embed and bridges its stdio to the WS
//     stream. Same RPC frames either way.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'editor_config.dart';
import 'log.dart';
import 'nvim_rpc_client.dart';

class NvimManager {
  static NvimManager? _shared;

  /// Singleton — one nvim --embed per lab. Subsequent EditSessions reuse.
  /// `theme` drives the in-grid `:highlight` palette (atom-one-dark by
  /// default). Pass an alternate `EditorTheme` to retheme the editor;
  /// the colors flow into the Lua bootstrap via
  /// `EditorTheme.toNvimHighlightLua()`.
  static Future<NvimManager> getOrCreate({
    required String nvimPath,
    EditorTheme theme = EditorTheme.atomOneDark,
  }) async {
    if (_shared != null) return _shared!;
    final mgr = NvimManager._(nvimPath: nvimPath, theme: theme);
    await mgr._start();
    _shared = mgr;
    return mgr;
  }

  /// Web/Chrome path: the lab is in the browser, so we cannot spawn a
  /// process. Connect to lab_chrome_proxy.py which has spawned its own
  /// `nvim --embed` and bridges stdio over a binary WebSocket.
  static Future<NvimManager> connectExisting({
    required String nvimWsUrl,
    EditorTheme theme = EditorTheme.atomOneDark,
  }) async {
    if (_shared != null) return _shared!;
    final mgr = NvimManager._external(nvimWsUrl: nvimWsUrl, theme: theme);
    await mgr._startExternal();
    _shared = mgr;
    return mgr;
  }

  static NvimManager? get sharedOrNull => _shared;

  final String nvimPath;
  final String? nvimWsUrl;
  final EditorTheme theme;
  Process? _proc;
  NvimRpcClient? rpc;

  // Namespace id for vim.diagnostic.set() — captured from the bootstrap
  // Lua's return value. Used by editor_widget._renderVimDiagnostics.
  int? diagNs;

  /// Highlight-attribute palette, keyed by `hl_id` from nvim's
  /// `hl_attr_define` redraw events. Stored at the manager scope (not
  /// inside `NvimViewState`) so it survives view rebuilds: when the
  /// orchestrator's `/edit` flow tears down the side panel and rebuilds
  /// it for a different control, nvim's UI stays attached and does
  /// NOT replay `hl_attr_define` for the new viewer — but the cells
  /// it now paints reference the same hl IDs (110, 122, …) that were
  /// established during the first attach. Without a manager-scoped
  /// palette every cell looked up an unknown id, fell back to the
  /// default attr, and the buffer lost all syntax color the moment
  /// the user opened a second `/edit`. Typed as `dynamic` because
  /// the `_HlAttr` class is private to `nvim_view.dart`; the manager
  /// just stashes the opaque values.
  final Map<int, dynamic> hlAttrs = {};

  bool _nvimAlive = false;
  String _nvimLastError = '';

  bool get isHealthy => _nvimAlive && rpc != null;
  String get lastError => _nvimLastError;

  // Notified whenever nvim's BufWriteCmd fires (i.e. the user typed :w).
  final StreamController<String> _saveStream = StreamController.broadcast();
  Stream<String> get onSave => _saveStream.stream;

  // Fires every time TextChanged*/BufModified* notifies us of a buffer
  // edit. Listeners (editor_widget) pull the buffer text and push it to
  // the LSP via didChange.
  final StreamController<int> _textChangedStream =
      StreamController<int>.broadcast();
  Stream<int> get onTextChanged => _textChangedStream.stream;

  NvimManager._({required this.nvimPath, required this.theme})
      : nvimWsUrl = null;

  NvimManager._external({required this.nvimWsUrl, required this.theme})
      : nvimPath = '';

  Future<void> _startExternal() async {
    debugPrint('[nvim.ext] connecting to $nvimWsUrl');
    rpc = NvimRpcClient();
    try {
      await rpc!.connectWebSocket(nvimWsUrl!);
      _nvimAlive = true;
    } catch (e) {
      _nvimLastError = 'WS connect: $e';
      rethrow;
    }
    rpc!.onDisconnect.listen((reason) {
      _nvimAlive = false;
      _nvimLastError = reason;
      debugPrint('[nvim] disconnected: $reason');
    });
    await _bootstrapAutocmds();
    // NB: ui_attach is deferred — NvimView calls attachUi() once it
    // has subscribed to onRedraw. Otherwise the initial hl_attr_define
    // flood lands before any subscriber and the renderer paints with
    // unknown hl_ids.
  }

  Future<void> _start() async {
    debugPrint('[nvim] spawning $nvimPath --embed');
    // -u NONE   : skip vimrc
    // --noplugin: skip plugin loading
    // -i NONE   : skip shada (no persistent state)
    // -n        : no swapfile
    final p = await Process.start(
      nvimPath,
      ['--embed', '-u', 'NONE', '--noplugin', '-i', 'NONE', '-n'],
      mode: ProcessStartMode.normal,
    );
    _proc = p;
    rpc = NvimRpcClient();
    try {
      await rpc!.connectProcess(p);
      _nvimAlive = true;
    } catch (e) {
      _nvimLastError = 'process bind: $e';
      rethrow;
    }
    rpc!.onDisconnect.listen((reason) {
      _nvimAlive = false;
      _nvimLastError = reason;
      debugPrint('[nvim] disconnected: $reason');
    });
    await _bootstrapAutocmds();
    // ui_attach is deferred until NvimView calls attachUi() (see above).
  }

  bool _uiAttached = false;

  /// Attach a UI so nvim emits `redraw` events. NvimView calls this
  /// AFTER it has subscribed to onRedraw, so the initial hl_attr_define
  /// flood reaches the painter rather than being emitted into the void.
  /// Idempotent — safe to call from successive view mounts.
  Future<void> attachUi() async {
    if (_uiAttached) return;
    _uiAttached = true;
    await _attachUi();
  }

  Future<void> _attachUi() async {
    try {
      await rpc!.request('nvim_ui_attach', [
        80,
        24,
        {
          'ext_linegrid': true,
          'ext_cmdline': true,
          'ext_popupmenu': true,
          'ext_messages': true,
          'ext_multigrid': false,
          'ext_hlstate': true,
          'rgb': true,
        },
      ]);
      debugPrint('[nvim] ui_attach OK');
    } catch (e) {
      debugPrint('[nvim] ui_attach failed: $e');
    }
  }

  // BufWriteCmd intercepts `:w` so saves flow through session.save()
  // instead of nvim writing to disk. Matches the prior bootstrap exactly,
  // just routed over stdio instead of TCP.
  Future<void> _bootstrapAutocmds() async {
    final chan = await rpc!.request('nvim_get_api_info', []);
    final chanId = (chan as List).first as int;
    debugPrint('[nvim] our RPC channel id: $chanId');

    // Two parts: the autocmd block needs $chanId interpolation, but the
    // f-string syntax regex (further down) needs raw backslashes that
    // would otherwise be eaten by Dart's string-escape rules. Compose
    // the interpolated head with a raw-string body via concatenation.
    final luaHead = '''
vim.api.nvim_create_autocmd("BufWriteCmd", {
  pattern = "*",
  callback = function(args)
    pcall(vim.fn.rpcnotify, $chanId, "lab_save", vim.api.nvim_buf_get_name(args.buf))
    vim.api.nvim_buf_set_option(args.buf, "modified", false)
  end,
})
vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI", "TextChangedP"}, {
  pattern = "*",
  callback = function(args)
    pcall(vim.fn.rpcnotify, $chanId, "lab_text_changed", args.buf)
  end,
})
''';
    const luaBody = r'''
vim.api.nvim_buf_set_name(0, "lab://session")
vim.api.nvim_buf_set_option(0, "buftype", "acwrite")
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
-- Enable mouse so nvim_input_mouse positions the cursor.
vim.opt.mouse = "a"
vim.opt.scrolloff = 999
vim.opt.signcolumn = "yes"
vim.cmd("filetype on")
vim.cmd("syntax on")
vim.api.nvim_buf_set_option(0, "filetype", "python")
vim.cmd("set number")
vim.cmd("set background=dark")
vim.opt.termguicolors = true
-- Highlight palette generated from EditorTheme. With no colorscheme
-- loaded these stick; with one loaded the per-group overrides win.
vim.cmd("highlight clear")
$themeHighlights

-- f-string interpolation: nvim's bundled python.vim has ZERO
-- f-string awareness — `f"..."` parses as identifier `f` + plain
-- pythonString. Define real f-string regions (single + triple
-- quoted, all prefix permutations) shaped like python.vim's own
-- pythonString. Inside, a pythonFStringExpression sub-region
-- matches `{…}` and uses contains=TOP so the inner expression
-- picks up identifiers/operators/numbers in their normal colors.
-- `\z(…)\z1` is vim's cross-region capture; plain `\1` won't
-- propagate from the start pattern to the end pattern.
-- f-string interpolation: bundled python.vim has zero f-string
-- awareness — `f"..."` parses as identifier `f` + pythonString.
-- Inject a match for `{…}` into any python string region.
-- IMPORTANT: registered via a FileType=python autocmd so it gets
-- re-applied every time python.vim re-loads (which happens on every
-- buffer rename / re-set of filetype, e.g. when setBufferText runs
-- `nvim_buf_set_option(buf, 'filetype', 'python')`). Without this
-- autocmd, the very first reload after the lab pushes its session
-- text wipes the syntax match via python.vim's `:syn clear`.
-- pythonFStringInterp + pythonFStringBrace highlights are emitted
-- by the theme palette block above. Here we only register the
-- syntax MATCH itself (and re-register on every FileType=python
-- because python.vim's `:syn clear` wipes it on each reload).
vim.cmd([[augroup epyx_lab_python_fstring]])
vim.cmd([[autocmd!]])
vim.cmd([[autocmd FileType python syn match pythonFStringInterp /{[^{}]\+}/ contained containedin=pythonString,pythonRawString]])
vim.cmd([[augroup END]])
-- Also apply to the current buffer NOW, since FileType has already
-- fired before this augroup was defined.
vim.cmd([[syn match pythonFStringInterp /{[^{}]\+}/ contained containedin=pythonString,pythonRawString]])

vim.opt.timeoutlen = 250
vim.opt.ttimeoutlen = 10
vim.diagnostic.config({
  signs = true,
  underline = true,
  virtual_text = { spacing = 2, prefix = "■" },
  severity_sort = true,
  update_in_insert = true,
})
pcall(function()
  vim.fn.sign_define("DiagnosticSignError", {text = "E", texthl = "DiagnosticSignError"})
  vim.fn.sign_define("DiagnosticSignWarn",  {text = "W", texthl = "DiagnosticSignWarn"})
  vim.fn.sign_define("DiagnosticSignInfo",  {text = "i", texthl = "DiagnosticSignInfo"})
  vim.fn.sign_define("DiagnosticSignHint",  {text = "h", texthl = "DiagnosticSignHint"})
end)
_G._lab_diag_ns = vim.api.nvim_create_namespace("lab_diag")
return _G._lab_diag_ns
''';
    // Build the theme palette lines — generated from EditorTheme so a
    // theme swap re-skins the in-grid syntax rendering. Spliced into
    // the raw-string body via a literal-string replace (the body
    // can't use Dart `$x` interpolation because of the regex
    // backslashes elsewhere in it).
    final lua = luaHead + luaBody.replaceFirst(
      r'$themeHighlights',
      theme.toNvimHighlightLua(),
    );
    final nsResult = await rpc!.request('nvim_exec_lua', [lua, []]);
    if (nsResult is num) {
      diagNs = nsResult.toInt();
      debugPrint('[nvim] diagnostic namespace = $diagNs');
    } else {
      debugPrint('[nvim] WARN: bootstrap returned non-numeric ns: $nsResult');
    }

    rpc!.notifications.listen((event) {
      if (event.method == 'lab_save') {
        labLog('[nvim] :w fired — bufname=${event.params}');
        _saveStream.add(event.params.isEmpty ? '' : event.params.first.toString());
      } else if (event.method == 'lab_text_changed') {
        final buf = event.params.isNotEmpty && event.params.first is num
            ? (event.params.first as num).toInt()
            : 0;
        _textChangedStream.add(buf);
      }
    });
  }

  Future<void> stop() async {
    try {
      await rpc?.close();
    } catch (_) {}
    try {
      _proc?.kill();
    } catch (_) {}
    if (!_saveStream.isClosed) await _saveStream.close();
    if (!_textChangedStream.isClosed) await _textChangedStream.close();
    if (_shared == this) _shared = null;
  }
}
