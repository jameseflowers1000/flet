// Shared source-of-truth for the unified editor widget.
//
// Both the Flutter-native editor and the embedded-nvim view operate on
// the SAME `EditSession`. Switching modes preserves buffer text, dirty
// state, save target, and (best-effort) cursor position — neither side
// owns the truth on its own.
//
// The session exposes:
//   - `text`      : full buffer source (lines joined by '\n')
//   - `cursor`    : (line, col), zero-indexed, line-then-col preserved
//                   across switches (re_editor uses offset; nvim uses
//                   line/col — converters live here)
//   - `dirty`     : flips true on any text mutation, false on save
//   - `save()`    : invokes the caller-supplied closure with the latest
//                   text; the closure tells us what to do with it (e.g.
//                   route to set_override(row, col, {kind:formula,...}))
//
// Listeners (ChangeNotifier) so widgets rebuild on text/cursor/dirty
// changes without prop-drilling.
import 'package:flutter/foundation.dart';

class CursorPos {
  final int line;
  final int column;
  const CursorPos({required this.line, required this.column});

  factory CursorPos.zero() => const CursorPos(line: 0, column: 0);

  /// Convert a flat-offset cursor (re_editor / TextEditingController
  /// style) into line/col by walking newlines in the source.
  factory CursorPos.fromOffset(String text, int offset) {
    if (offset <= 0) return const CursorPos(line: 0, column: 0);
    int line = 0, col = 0;
    final n = text.length < offset ? text.length : offset;
    for (int i = 0; i < n; i++) {
      if (text.codeUnitAt(i) == 0x0a) {
        line++;
        col = 0;
      } else {
        col++;
      }
    }
    return CursorPos(line: line, column: col);
  }

  /// Convert line/col back to flat offset for re_editor.
  int toOffset(String text) {
    int curLine = 0, off = 0;
    final len = text.length;
    while (off < len && curLine < line) {
      if (text.codeUnitAt(off) == 0x0a) curLine++;
      off++;
    }
    final lineEnd = text.indexOf('\n', off);
    final lineLen = (lineEnd < 0 ? len : lineEnd) - off;
    return off + (column < lineLen ? column : lineLen);
  }

  @override
  String toString() => 'CursorPos($line:$column)';
}

/// Caller-supplied save target. Returns true on success.
typedef SaveCallback = Future<bool> Function(String text);

class EditSession extends ChangeNotifier {
  String _text;
  CursorPos _cursor;
  bool _dirty = false;
  final SaveCallback? _onSave;

  /// Identifier shown in the chrome — e.g. "row 5 / Payment", or the
  /// control name for control-code editing.
  final String label;

  /// Identity for the LSP — these three together drive the URI shape
  /// `epyx_edit_<controlName>(_column_<columnName>)?_<attribute>.py`,
  /// which `epyx.lsp.context._FILENAME_RE` parses back into an
  /// `EditingContext`. Production callers should pass the live
  /// Property's identifier as `controlName`; for the lab we sanitize
  /// the label.
  ///   - `controlName` : Property identifier (e.g. `"amort_code"`)
  ///   - `attribute`   : `"code"` / `"value_code"` / `"spec_code"` / etc.
  ///   - `columnName`  : ETab column name when editing a per-cell
  ///                     formula; null for whole-control edits.
  final String controlName;
  final String attribute;
  final String? columnName;

  /// When non-null, returned verbatim from `lspUri` instead of being
  /// constructed from the identity fields. Set by integrations where
  /// the host (Python orchestrator) already knows the URI shape the
  /// LSP server expects and we shouldn't re-derive it.
  final String? _lspUriOverride;

  EditSession({
    required String initialText,
    this.label = '',
    String? controlName,
    this.attribute = 'code',
    this.columnName,
    String? lspUriOverride,
    SaveCallback? onSave,
  })  : _text = initialText,
        _cursor = CursorPos.zero(),
        _onSave = onSave,
        _lspUriOverride = lspUriOverride,
        controlName = controlName ?? _sanitize(label);

  /// Sanitize a free-form label into something `_FILENAME_RE` will accept
  /// (alnum + `_` only). Used as the fallback when no explicit
  /// controlName is provided (lab fixtures).
  static String _sanitize(String s) {
    final t = s
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return t.isEmpty ? 'lab_session' : t;
  }

  /// The single LSP URI for this session — used by both the EZ editor's
  /// `didOpen`/`didChange` and the vim view's diagnostic round-trip.
  /// Built once from the identity fields above so every consumer agrees.
  String get lspUri {
    final ov = _lspUriOverride;
    if (ov != null && ov.isNotEmpty) {
      return ov;
    }
    // `--` (double-dash) separator between control name and attribute.
    // Single-underscore was ambiguous when control names end in legacy
    // `_code`-style attrs (e.g. `plan_display` + `code` parsed as
    // `plan` + `display_code` on the server). See
    // `epyx.lsp.context._FILENAME_RE` for the matching parser.
    final colSeg = (columnName != null && columnName!.isNotEmpty)
        ? '--column_${_sanitize(columnName!)}'
        : '';
    return 'file:///tmp/epyx_edit_$controlName$colSeg--$attribute.py';
  }

  String get text => _text;
  CursorPos get cursor => _cursor;
  bool get dirty => _dirty;

  /// Update text from one of the editors. `markDirty=false` suppresses
  /// the dirty flip — useful when an editor is just echoing a buffer
  /// switch (loaded text from the OTHER editor, not a user mutation).
  void setText(String value, {bool markDirty = true}) {
    if (value == _text) return;
    _text = value;
    if (markDirty) _dirty = true;
    notifyListeners();
  }

  void setCursor(CursorPos pos) {
    if (pos.line == _cursor.line && pos.column == _cursor.column) return;
    _cursor = pos;
    notifyListeners();
  }

  Future<bool> save() async {
    if (_onSave == null) return false;
    final ok = await _onSave(_text);
    if (ok) {
      _dirty = false;
      notifyListeners();
    }
    return ok;
  }
}
