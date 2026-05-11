// Centralized configuration surface for the unified editor. Pulls the
// previously-scattered constants (font choice, palette, popup
// geometry, key bindings, fallback hover docs) into one place so the
// main-repo integration can theme / size / rebind the editor without
// forking the lab's individual files.
//
// Defaults match the lab's current behavior 1:1; passing nothing
// preserves what users see today. Sub-configs are immutable
// `const`-constructible records so callers can compose them in a
// const Map without runtime cost.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Top-level config bundle. Pass via `UnifiedEditor.config`.
@immutable
class EditorConfig {
  final EditorTheme theme;
  final EditorFont font;
  final EditorPopupGeometry popup;
  final EditorKeyBindings keys;

  /// Hover-doc fallbacks for tokens the LSP returns nothing for. Keyed
  /// by bare identifier (e.g. `'the'`, `'o'`); values are the panel
  /// body text. Main repo can override with project-specific notes.
  final Map<String, String> hoverFallbacks;

  const EditorConfig({
    this.theme = EditorTheme.atomOneDark,
    this.font = EditorFont.menlo,
    this.popup = const EditorPopupGeometry(),
    this.keys = const EditorKeyBindings(),
    this.hoverFallbacks = const {},
  });
}

/// Color palette covering the editor body, syntax tokens, diagnostics,
/// and the popup chrome. atom-one-dark is the default; light/brand
/// variants can be added by constructing a new `EditorTheme`.
@immutable
class EditorTheme {
  // ── editor body ────────────────────────────────────────────────────
  final Color bg;
  final Color fg;
  final Color cursorLine;
  final Color selection;

  // ── syntax tokens (atom-one-dark hex palette by default) ──────────
  final Color comment;
  final Color keyword;
  final Color operator;
  final Color string;
  final Color number;
  final Color builtin;
  final Color function;
  final Color identifier;
  final Color type;

  // ── diagnostics ───────────────────────────────────────────────────
  final Color error;
  final Color warning;
  final Color info;

  // ── popup + hover panel chrome ────────────────────────────────────
  final Color popupBg;
  final Color popupBorder;
  final Color popupFg;
  final Color popupDetailFg;
  final Color popupSelectedBg;
  final Color popupSelectedFg;
  final Color popupSelectedDetailFg;

  const EditorTheme({
    required this.bg,
    required this.fg,
    required this.cursorLine,
    required this.selection,
    required this.comment,
    required this.keyword,
    required this.operator,
    required this.string,
    required this.number,
    required this.builtin,
    required this.function,
    required this.identifier,
    required this.type,
    required this.error,
    required this.warning,
    required this.info,
    required this.popupBg,
    required this.popupBorder,
    required this.popupFg,
    required this.popupDetailFg,
    required this.popupSelectedBg,
    required this.popupSelectedFg,
    required this.popupSelectedDetailFg,
  });

  /// Atom-One-Dark palette — current default. Hex values match the
  /// re_highlight `atom-one-dark.dart` theme so EZ and the rest of
  /// the lab stay in sync.
  /// Render this theme into a flat map of highlight-group → CSS-style
  /// `#rrggbb` strings, ready to splice into nvim's `:highlight` Lua.
  /// Keys match neovim's standard syntax-group names so a theme swap
  /// re-themes the in-grid Python rendering with no other changes.
  Map<String, String> toNvimHighlightHex() => <String, String>{
        'Normal':       '${_hex(fg)} guibg=${_hex(bg)}',
        'Comment':      '${_hex(comment)} gui=italic',
        'Constant':     _hex(number),
        'String':       _hex(string),
        'Character':    _hex(string),
        'Number':       _hex(number),
        'Float':        _hex(number),
        'Boolean':      _hex(number),
        'Identifier':   _hex(identifier),
        'Function':     _hex(function),
        'Statement':    _hex(keyword),
        'Conditional':  _hex(keyword),
        'Repeat':       _hex(keyword),
        'Label':        _hex(keyword),
        'Operator':     _hex(operator),
        'Keyword':      _hex(keyword),
        'Exception':    _hex(keyword),
        'PreProc':      _hex(keyword),
        'Include':      _hex(keyword),
        'Define':       _hex(keyword),
        'Macro':        _hex(keyword),
        'Type':         _hex(type),
        'StorageClass': _hex(type),
        'Structure':    _hex(type),
        'Special':      _hex(operator),
        'Delimiter':    _hex(fg),
        'LineNr':       _hex(comment),
        'CursorLineNr': '${_hex(fg)} gui=bold',
        'CursorLine':   'NONE guibg=${_hex(cursorLine)}',
        'Visual':       'NONE guibg=${_hex(selection)}',
        'pythonFStringBrace':       _hex(fg),
        'pythonFStringInterp':      _hex(identifier),
        'DiagnosticSignError':      _hex(error),
        'DiagnosticSignWarn':       _hex(warning),
        'DiagnosticSignInfo':       _hex(info),
        'DiagnosticSignHint':       _hex(operator),
        'DiagnosticUnderlineError':
            'NONE gui=undercurl guisp=${_hex(error)}',
        'DiagnosticUnderlineWarn':
            'NONE gui=undercurl guisp=${_hex(warning)}',
        'DiagnosticUnderlineInfo':
            'NONE gui=undercurl guisp=${_hex(info)}',
        'DiagnosticVirtualTextError': _hex(error),
        'DiagnosticVirtualTextWarn':  _hex(warning),
        'DiagnosticVirtualTextInfo':  _hex(info),
      };

  /// Build the `:highlight <group> guifg=...` command list as Lua
  /// source. Pasted into NvimManager's bootstrap chunk so a theme
  /// swap reskins the in-grid syntax rendering.
  String toNvimHighlightLua() {
    final lines = <String>[];
    toNvimHighlightHex().forEach((group, spec) {
      // `spec` already starts with either a hex foreground or 'NONE'.
      // Insert `guifg=` only if it begins with `#`.
      final body = spec.startsWith('#') ? 'guifg=$spec' : spec;
      lines.add("vim.cmd('highlight $group $body')");
    });
    return lines.join('\n');
  }

  static String _hex(Color c) {
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    return '#'
        '${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  static const atomOneDark = EditorTheme(
    bg: Color(0xFF111111),
    fg: Color(0xFFCCCCCC),
    cursorLine: Color(0xFF1B1D23),
    selection: Color(0xFF3E4452),
    comment: Color(0xFF5C6370),
    keyword: Color(0xFFC678DD),
    operator: Color(0xFF56B6C2),
    string: Color(0xFF98C379),
    number: Color(0xFFD19A66),
    builtin: Color(0xFF61AFEF),
    function: Color(0xFF61AFEF),
    identifier: Color(0xFFE06C75),
    type: Color(0xFFE5C07B),
    error: Color(0xFFE05A5A),
    warning: Color(0xFFFFAA33),
    info: Color(0xFF66AAFF),
    popupBg: Color(0xFF1B1F1A),
    popupBorder: Color(0xFF2E3A2A),
    popupFg: Color(0xFFCCCCCC),
    popupDetailFg: Color(0xFF7E9F70),
    popupSelectedBg: Color(0xFF2E4A1F),
    popupSelectedFg: Color(0xFFD7F0BA),
    popupSelectedDetailFg: Color(0xFFB6D69E),
  );
}

/// Font choice + per-character pitch. Same family/size/height drives
/// both editors, the popup, and the hover panel — so swapping
/// `EditorFont` reskins the whole surface.
@immutable
class EditorFont {
  /// Primary font family. On macOS `Menlo` is a safe default;
  /// non-macOS callers should pass a bundled family or system default.
  final String family;
  final List<String> familyFallback;
  final double size;

  /// Line-height multiplier (`fontSize * height` = row height in px).
  final double height;

  /// Per-character pitch widening on classified spans in EZ. Variables
  /// and operators inherit from baseStyle (without letterSpacing) so
  /// the visual mismatch is small for typical Python.
  final double letterSpacing;

  /// Popup label / detail font sizes. Slightly smaller than the
  /// editor body so the popup feels secondary.
  final double popupFontSize;
  final double popupDetailFontSize;

  const EditorFont({
    required this.family,
    this.familyFallback = const [],
    this.size = 13,
    this.height = 1.5,
    this.letterSpacing = 0.6,
    this.popupFontSize = 13,
    this.popupDetailFontSize = 11,
  });

  static const menlo = EditorFont(
    family: 'JetBrainsMono',
    familyFallback: ['JetBrainsMono', 'SF Mono', 'Consolas', 'monospace'],
  );
}

/// Sizing knobs for the popup. Geometry is variable-height up to
/// `maxHeight`; selection auto-scrolls inside that band.
@immutable
class EditorPopupGeometry {
  final double width;
  final double minHeight;
  final double maxHeight;

  const EditorPopupGeometry({
    this.width = 480,
    this.minHeight = 40,
    this.maxHeight = 520,
  });
}

/// Editor-level key bindings. Defaults map to the conventions the lab
/// has shipped with; integrators may swap them to match their host
/// app's conventions (e.g. `Cmd-V` for toggle if `Cmd-/` is taken).
@immutable
class EditorKeyBindings {
  final ShortcutActivator showHoverDocs;
  final ShortcutActivator showHoverDocsCtrl;
  final ShortcutActivator save;
  final ShortcutActivator saveCtrl;
  final ShortcutActivator toggleMode;
  final ShortcutActivator toggleModeCtrl;

  const EditorKeyBindings({
    this.showHoverDocs =
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
    this.showHoverDocsCtrl =
        const SingleActivator(LogicalKeyboardKey.keyK, control: true),
    this.save =
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
    this.saveCtrl =
        const SingleActivator(LogicalKeyboardKey.keyS, control: true),
    this.toggleMode =
        const SingleActivator(LogicalKeyboardKey.slash, meta: true),
    this.toggleModeCtrl =
        const SingleActivator(LogicalKeyboardKey.slash, control: true),
  });
}
