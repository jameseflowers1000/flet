// Flutter-native editor view — wraps `re_editor` with Python syntax
// highlighting via `re_highlight`. Reads/writes the shared `EditSession`.
//
// LSP wiring: when a non-null `lsp` is passed, didOpen on mount, didChange
// debounced on edits, and the completion popup pulls from
// `LspCompletionPromptsBuilder`. Diagnostics (squiggles) come next.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:re_highlight/styles/atom-one-dark.dart';

import 'edit_session.dart';
import 'haiku_rewrite.dart';
import 'lsp_client.dart';
import 'lsp_completion_provider.dart';
import 'vim_completion_popup.dart' show
    kPopupBg,
    kPopupBorder,
    kPopupMaxHeight,
    kPopupMinHeight,
    kPopupWidth,
    popupRow;

// hljs's python mode lumps every keyword into the `keyword` class, so
// EZ shows `for` and `in` in the same color. nvim's syntax/python.vim
// classes `in`/`is`/`not`/`and`/`or` as `pythonOperator` (a separate
// highlight group) — to match, prepend a single-shot match Mode that
// claims operator keywords with a distinct flat scope. The scope must
// NOT contain a `.` because `_HighlightLineRenderer` in re_editor
// (line 315 of _code_highlight.dart) splits scope on `.` and keeps
// only the first segment for theme lookup, which would collapse
// `keyword.operator` back to `keyword` and re-pick the purple style.
const _kPythonOperatorScope = 'pythonOperator';
final _operatorKeywordMode = Mode(
  scope: _kPythonOperatorScope,
  match: r'\b(?:in|is|not|and|or)\b',
  relevance: 0,
);

// Wrap langPython with our extra mode in front of its `contains`. The
// rest of langPython's structure (keywords map, sub-modes for strings,
// f-strings, decorators, classes, etc.) stays as-is.
final _langPythonLab = langPython.copyWith(
  Mode(contains: [_operatorKeywordMode, ...?langPython.contains]),
);

// Per-character pitch widening. re_editor's CodeEditorStyle doesn't
// expose `letterSpacing`, and `baseStyle` (the outer TextSpan style)
// is built without it, so we apply it via every theme entry — Flutter
// merges parent + child TextStyles, so a child with letterSpacing wins
// for that span.
//
// Limitation: bare identifiers (`i`, `x`), operator punctuation
// (`=` `(` `)` `**` `:`), and whitespace are unclassified — they
// inherit baseStyle directly and therefore won't pick up letterSpacing.
// In typical Python code that's mostly punctuation between classified
// tokens, where the visual mismatch is small, but it isn't perfectly
// uniform. Removing this constraint cleanly would require forking
// re_editor to expose letterSpacing on CodeEditorStyle.
const _kLetterSpacing = 0.6;

TextStyle _withSpacing(TextStyle s) =>
    s.copyWith(letterSpacing: _kLetterSpacing);

// Atom-One-Dark with two scope-color overrides + letterSpacing on
// every entry:
//   * built_in: range/print/len/etc. → blue (was yellow)
//   * pythonOperator (custom flat scope from _operatorKeywordMode) →
//     cyan, matching nvim's pythonOperator group
final _labCodeTheme = <String, TextStyle>{
  for (final e in atomOneDarkTheme.entries) e.key: _withSpacing(e.value),
  'built_in': _withSpacing(const TextStyle(color: Color(0xff61afef))),
  _kPythonOperatorScope:
      _withSpacing(const TextStyle(color: Color(0xff56b6c2))),
};

class NativeEditor extends StatefulWidget {
  final EditSession session;
  final LspClient? lsp;
  final String uri;
  /// Fired when the cursor moves, with (line, col). Used by the
  /// parent (UnifiedEditor) to keep the status bar in sync.
  final void Function(int line, int col)? onCursor;
  /// Diagnostics for this document, refreshed by the parent on
  /// publishDiagnostics. Renders as wavy underlines via spanBuilder.
  final List<LspDiagnostic> diagnostics;
  /// Cmd-/ toggle to flip between EZ and Vim. Passed in (rather than
  /// bound on the outer chrome) because re_editor's CodeEditor swallows
  /// most printable keystrokes at the platform-input layer before our
  /// outer CallbackShortcuts gets to see them.
  final VoidCallback? onToggleMode;
  const NativeEditor({
    super.key,
    required this.session,
    this.lsp,
    required this.uri,
    this.onCursor,
    this.diagnostics = const [],
    this.onToggleMode,
  });

  @override
  State<NativeEditor> createState() => NativeEditorState();
}

// Public name so UnifiedEditor can grab the State via a GlobalKey
// and call `grabFocus()` on mode switch.
typedef NativeEditorStateKey = GlobalKey<NativeEditorState>;

class NativeEditorState extends State<NativeEditor> {
  late final CodeLineEditingController _controller;
  late final FocusNode _focusNode = FocusNode();
  bool _suppressEcho = false;
  int _lspVersion = 1;
  Timer? _didChangeDebounce;
  LspCompletionPromptsBuilder? _completions;
  // Snapshot of the buffer text just before the most recent change.
  // We compare against post-change text to detect re_editor's auto-
  // paired quote insertion (it doubles up `'` / `"` and places the
  // cursor between the pair). When that pair fires inside a Python
  // comment, we undo the closing quote — typing `doesn't` shouldn't
  // become `doesn't'`.
  String _prevText = '';

  /// Public hook so the parent (UnifiedEditor) can pull focus into
  /// this editor when the user flips back to EZ mode — without it
  /// they'd have to click or Tab into the editor before typing.
  void grabFocus() {
    if (mounted) _focusNode.requestFocus();
  }

  /// Current cursor position, 0-based (line, column). Used by the
  /// parent on mode switch to mirror across editors.
  (int, int) getCursor() {
    final sel = _controller.selection;
    return (sel.extentIndex, sel.extentOffset);
  }

  /// The text on the line currently containing the cursor, or null
  /// when no buffer text is available. The chrome uses this for
  /// hover-fallback identifier lookup.
  String? lineAtCursor() {
    final sel = _controller.selection;
    final lines = _controller.text.split('\n');
    if (sel.extentIndex < 0 || sel.extentIndex >= lines.length) return null;
    return lines[sel.extentIndex];
  }

  /// Place the cursor at (line, col) — clamped to the buffer's bounds.
  void setCursor(int line, int col) {
    final lines = _controller.text.split('\n');
    final l = line.clamp(0, (lines.length - 1).clamp(0, 1 << 30));
    final lineLen = l < lines.length ? lines[l].length : 0;
    final c = col.clamp(0, lineLen);
    _controller.selection = CodeLineSelection.collapsed(
      index: l,
      offset: c,
    );
  }

  /// Undo / redo through re_editor's controller so the chrome can
  /// surface them as toolbar buttons.
  void undo() {
    if (_controller.canUndo) _controller.undo();
  }

  void redo() {
    if (_controller.canRedo) _controller.redo();
  }

  bool get canUndo => _controller.canUndo;
  bool get canRedo => _controller.canRedo;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController(
      codeLines: CodeLines.fromText(widget.session.text),
      options: const CodeLineOptions(indentSize: 4),
      spanBuilder: _buildSpanWithDiagnostics,
    );
    _prevText = _controller.text;
    _controller.addListener(_onLocalChange);
    widget.session.addListener(_onSessionChange);
    _initLsp();
  }

  void _initLsp() {
    final lsp = widget.lsp;
    if (lsp == null) return;
    lsp.didOpen(widget.uri, widget.session.text);
    _completions = LspCompletionPromptsBuilder(
      lsp: lsp,
      uri: widget.uri,
      currentText: () => _controller.text,
      bumpVersion: () => ++_lspVersion,
    );
  }

  @override
  void didUpdateWidget(covariant NativeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged = oldWidget.session != widget.session;
    if (sessionChanged) {
      oldWidget.session.removeListener(_onSessionChange);
      widget.session.addListener(_onSessionChange);
      _syncFromSession();
    }
    // LSP started after this editor mounted (it spawns async — the
    // lab can build the editor with `lsp: null` and only later set the
    // real instance via setState in LabHome). When the late-arriving
    // LSP shows up, run the same wiring that initState would have.
    if (oldWidget.lsp == null && widget.lsp != null) {
      _initLsp();
    }
    // Diagnostics changed → ask re_editor (our local fork) to refresh
    // its cached paragraphs so spanBuilder re-runs and the wavy
    // underlines update in real time, WITHOUT dismissing the
    // autocomplete popup. forceRepaint() fires notifyListeners with
    // the value unchanged; the forked _CodeLineEditableState detects
    // that case and skips its dismiss-autocomplete branch while still
    // calling markNeedsLayout on the field, so paragraphs rebuild.
    //
    // CRITICAL: skip forceRepaint when the session ALSO changed this
    // update. `_syncFromSession()` above just swapped `_controller.text`
    // to the new buffer, but re_editor's `_CodeFieldRender` still holds
    // a paragraph cache sized for the OLD buffer. forceRepaint() walks
    // that stale cache and indexes the new (often shorter) `CodeLines`
    // — `CodeLines[20]` on a 20-line buffer → RangeError → the whole
    // NativeEditor throws and Flutter replaces it with a grey
    // RenderErrorBox that crushes the editor layout. The text swap
    // already triggers a normal repaint that rebuilds paragraphs
    // against the correct line count; the diagnostics are cleared to
    // `[]` on a session swap anyway, so there is nothing extra to
    // refresh.
    if (oldWidget.diagnostics != widget.diagnostics && !sessionChanged) {
      _controller.forceRepaint();
    }
  }

  @override
  void dispose() {
    _didChangeDebounce?.cancel();
    _controller.removeListener(_onLocalChange);
    widget.session.removeListener(_onSessionChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onLocalChange() {
    // Cursor callback fires every time selection or text changes;
    // safe to invoke even during _suppressEcho since it only updates
    // the parent's status display, not session state.
    final sel = _controller.selection;
    widget.onCursor?.call(sel.extentIndex, sel.extentOffset);

    if (_suppressEcho) return;
    // Detect & undo re_editor's quote auto-pair when fired in a comment.
    _maybeUndoCommentQuotePair();
    // Detect Enter-on-?? line and trigger Haiku rewrite. Runs BEFORE
    // we update _prevText so the diff is preserved for the heuristic.
    _maybeHaikuRewriteOnNewline();
    final localText = _controller.text;
    _prevText = localText;
    if (localText != widget.session.text) {
      widget.session.setText(localText);
    }
    final lsp = widget.lsp;
    if (lsp == null) return;
    // Debounce didChange — rapid keystrokes shouldn't flood the server.
    _didChangeDebounce?.cancel();
    _didChangeDebounce = Timer(const Duration(milliseconds: 120), () {
      _lspVersion++;
      lsp.didChange(widget.uri, _controller.text, version: _lspVersion);
    });
    // Prefetch completions IMMEDIATELY (before re_editor's 50ms-delayed
    // build() fires). The fetch will sync didChange itself, so server
    // sees the live buffer. By the time build() runs, the cache is hot
    // and the popup pops on the very first keystroke / dot trigger.
    final c = _completions;
    if (c != null) {
      final sel = _controller.selection;
      final lines = _controller.text.split('\n');
      final lineIdx = sel.endIndex.clamp(0, lines.length - 1);
      final lineText = lines[lineIdx];
      final col = sel.endOffset.clamp(0, lineText.length);
      c.prefetch(lineIdx, col, lineText);
    }
  }

  void _maybeUndoCommentQuotePair() {
    final newText = _controller.text;
    final sel = _controller.selection;
    // Conditions: text grew by exactly 2 chars, cursor collapsed,
    // both chars at the cursor are the same quote, AND the line
    // (with the auto-pair stripped) is in comment context up to
    // the user-typed quote.
    if (!sel.isCollapsed) return;
    if (newText.length != _prevText.length + 2) return;
    final lines = newText.split('\n');
    final lineIdx = sel.endIndex;
    if (lineIdx < 0 || lineIdx >= lines.length) return;
    final lineText = lines[lineIdx];
    final col = sel.endOffset;
    if (col <= 0 || col >= lineText.length) return;
    final left = lineText[col - 1];
    final right = lineText[col];
    if (left != right) return;
    if (left != "'" && left != '"' && left != '`') return;
    // Run a comment detector on the line UP TO the user-typed quote
    // so the inserted pair doesn't itself flip us into "string mode".
    final beforeUserQuote = lineText.substring(0, col - 1);
    if (!_isCommentLineUpTo(beforeUserQuote)) return;
    // Strip the closing quote at `col`. Rebuild the line, splice
    // back into the full text, and reset selection at `col`
    // (one before the deleted char — cursor stays where the user
    // last left it).
    final newLine = lineText.substring(0, col) + lineText.substring(col + 1);
    lines[lineIdx] = newLine;
    final spliced = lines.join('\n');
    _suppressEcho = true;
    try {
      _controller.text = spliced;
      _controller.selection =
          CodeLineSelection.collapsed(index: lineIdx, offset: col);
    } finally {
      _suppressEcho = false;
    }
  }

  /// Index diagnostics by line for quick spanBuilder lookup.
  Map<int, List<LspDiagnostic>> _diagnosticsByLine() {
    final m = <int, List<LspDiagnostic>>{};
    for (final d in widget.diagnostics) {
      // Diagnostics can span multiple lines; mark every line in range.
      for (int l = d.line; l <= d.endLine; l++) {
        m.putIfAbsent(l, () => <LspDiagnostic>[]).add(d);
      }
    }
    return m;
  }

  TextSpan _buildSpanWithDiagnostics({
    required BuildContext context,
    required int index,
    required CodeLine codeLine,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    final byLine = _diagnosticsByLine();
    final ds = byLine[index];
    if (ds == null || ds.isEmpty) return textSpan;
    // Pick the worst severity: 1=Error red, 2=Warning amber, 3=Info,
    // 4=Hint. Single underline color per line, simple but readable.
    int worst = ds.map((d) => d.severity).reduce((a, b) => a < b ? a : b);
    final col = worst == 1
        ? const Color(0xFFE05A5A) // error red
        : worst == 2
            ? const Color(0xFFFFAA33) // warning amber
            : const Color(0xFF66AAFF); // info blue
    // Wrap the original textSpan in a parent span carrying the wavy
    // underline. The decoration cascades to children unless they
    // override it. For α use this is good enough to show "something's
    // wrong on this line"; precise per-character ranges would need
    // recursive span splitting.
    return TextSpan(
      style: TextStyle(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: col,
      ),
      children: [textSpan],
    );
  }

  /// True iff a Python `#` comment marker exists in `text` outside any
  /// `'…'`/`"…"` string. Single-line heuristic — same approach as the
  /// completion-popup gate, but kept local here to avoid a cross-file
  /// dep just for this tiny check.
  bool _isCommentLineUpTo(String text) {
    String? quote;
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quote == null) {
        if (ch == '#') return true;
        if (ch == "'" || ch == '"' || ch == '`') quote = ch;
      } else {
        if (ch == r'\' && i + 1 < text.length) {
          i++;
          continue;
        }
        if (ch == quote) quote = null;
      }
    }
    return false;
  }

  void _onSessionChange() {
    if (_controller.text == widget.session.text) return;
    _syncFromSession();
  }

  void _syncFromSession() {
    _suppressEcho = true;
    try {
      _controller.text = widget.session.text;
    } finally {
      _suppressEcho = false;
    }
  }

  /// After every text change, check if the user just hit Enter on a
  /// `??` line (the line ABOVE the cursor's new position is a magic
  /// line, and the change was a single newline insertion). If so,
  /// remove the empty line just created and replace the magic line
  /// with the Haiku rewrite result. Triggered post-change because
  /// re_editor consumes Enter at the platform-input layer; we can't
  /// intercept it ahead of time without forking the package.
  void _maybeHaikuRewriteOnNewline() {
    final newText = _controller.text;
    if (newText.length != _prevText.length + 1) return;
    final sel = _controller.selection;
    if (!sel.isCollapsed) return;
    final lines = newText.split('\n');
    final cursorLine = sel.endIndex;
    if (cursorLine <= 0 || cursorLine >= lines.length) return;
    // The previous line — should be the magic `??` line untouched
    // by the newline insertion.
    final prevLineIdx = cursorLine - 1;
    final prevLine = lines[prevLineIdx];
    if (!HaikuRewrite.isMagicLine(prevLine)) return;
    // Cursor should be at the START of the new line for this to be
    // a "press Enter at end of magic line" event.
    if (sel.endOffset != 0) return;
    _runHaikuRewrite(prevLineIdx, prevLine, removeNextLine: true);
  }

  Future<void> _runHaikuRewrite(int lineIdx, String original,
      {bool removeNextLine = false}) async {
    final indent = RegExp(r'^\s*').firstMatch(original)?.group(0) ?? '';
    _replaceLine(lineIdx, '$indent# ?? thinking…',
        removeNextLine: removeNextLine);
    final result = await HaikuRewrite.rewriteLine(original);
    if (!mounted) return;
    if (result == null || result.isEmpty) {
      _replaceLine(lineIdx, original);
      return;
    }
    final indented =
        result.split('\n').map((l) => l.isEmpty ? l : '$indent$l').join('\n');
    _replaceLine(lineIdx, indented);
  }

  void _replaceLine(int lineIdx, String newContent,
      {bool removeNextLine = false}) {
    final lines = _controller.text.split('\n');
    if (lineIdx < 0 || lineIdx >= lines.length) return;
    final newLines = List<String>.from(lines);
    final replacement = newContent.split('\n');
    final endIdxExclusive = removeNextLine && lineIdx + 1 < newLines.length
        ? lineIdx + 2
        : lineIdx + 1;
    newLines.replaceRange(lineIdx, endIdxExclusive, replacement);
    _suppressEcho = true;
    try {
      _controller.text = newLines.join('\n');
      final endLine = lineIdx + replacement.length - 1;
      final endCol = replacement.last.length;
      _controller.selection =
          CodeLineSelection.collapsed(index: endLine, offset: endCol);
    } finally {
      _suppressEcho = false;
    }
  }

  Widget _wrapAutocomplete(Widget child) {
    final c = _completions;
    if (c == null) return child;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) => CodeAutocomplete(
        promptsBuilder: c,
        viewBuilder: (context, notifier, onSelected) =>
            _LspCompletionPopup(notifier: notifier, onSelected: onSelected),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
          widget.session.save();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          widget.session.save();
        },
        if (widget.onToggleMode != null) ...{
          const SingleActivator(LogicalKeyboardKey.slash, meta: true):
              widget.onToggleMode!,
          const SingleActivator(LogicalKeyboardKey.slash, control: true):
              widget.onToggleMode!,
        },
      },
      child: Focus(
        // Outer Focus is for Cmd-S only — re_editor consumes printable
        // keys at the platform-input layer, so onKeyEvent on this
        // wrapper doesn't see them. Haiku detection runs in the
        // controller listener instead (see _maybeHaikuRewriteOnNewline).
        autofocus: false,
        child: _wrapAutocomplete(
          CodeEditor(
            controller: _controller,
            focusNode: _focusNode,
            // Do NOT autofocus. `EditorWidget._claimEditorFocus()` is
            // the single source of truth for which editor holds focus
            // — autofocus here would re-fire on widget rebuilds (each
            // diagnostic publish triggers `setState` upstream), stealing
            // focus from the visible nvim view in mid-edit.
            autofocus: false,
            style: CodeEditorStyle(
              fontSize: 13,
              fontFamily: 'JetBrainsMono',
              fontHeight: 1.5,
              backgroundColor: const Color(0xFF111111),
              codeTheme: CodeHighlightTheme(
                languages: {
                  'python': CodeHighlightThemeMode(mode: _langPythonLab),
                },
                theme: _labCodeTheme,
              ),
            ),
            indicatorBuilder:
                (context, editingController, chunkController, notifier) {
              // E/W glyph column to the left of the line numbers,
              // mirroring nvim's `signcolumn=yes` rendering. Drives
              // off the same `widget.diagnostics` list the wavy
              // underline pass uses.
              return Row(
                children: [
                  _DiagnosticGutter(
                    diagnostics: widget.diagnostics,
                    notifier: notifier,
                    rowHeight: _kEzRowHeight,
                  ),
                  DefaultCodeLineNumber(
                    controller: editingController,
                    notifier: notifier,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// Approximate paint-per-row height for fontSize=13, fontHeight=1.5.
// Matches DefaultCodeLineNumber's row height so the diag glyphs stay
// vertically aligned with the line numbers next to them.
const double _kEzRowHeight = 13 * 1.5;

class _DiagnosticGutter extends StatelessWidget {
  final List<LspDiagnostic> diagnostics;
  final CodeIndicatorValueNotifier notifier;
  final double rowHeight;
  const _DiagnosticGutter({
    required this.diagnostics,
    required this.notifier,
    required this.rowHeight,
  });

  @override
  Widget build(BuildContext context) {
    // Index worst severity per line — same logic as the wavy
    // underline pass uses.
    final worst = <int, int>{};
    for (final d in diagnostics) {
      for (int l = d.line; l <= d.endLine; l++) {
        final cur = worst[l];
        if (cur == null || d.severity < cur) worst[l] = d.severity;
      }
    }
    return AnimatedBuilder(
      animation: notifier,
      builder: (context, _) {
        final value = notifier.value;
        return SizedBox(
          width: 14,
          child: Stack(
            children: [
              if (value != null)
                for (final p in value.paragraphs)
                  if (worst.containsKey(p.index))
                    Positioned(
                      left: 0,
                      right: 0,
                      top: p.top,
                      height: p.height,
                      child: Center(
                        child: Text(
                          worst[p.index] == 1
                              ? 'E'
                              : (worst[p.index] == 2 ? 'W' : 'i'),
                          style: TextStyle(
                            color: worst[p.index] == 1
                                ? const Color(0xFFE05A5A)
                                : (worst[p.index] == 2
                                    ? const Color(0xFFFFAA33)
                                    : const Color(0xFF66AAFF)),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        );
      },
    );
  }
}

class _LspCompletionPopup extends StatefulWidget
    implements PreferredSizeWidget {
  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;
  const _LspCompletionPopup({required this.notifier, required this.onSelected});

  @override
  Size get preferredSize => Size(kPopupWidth, kPopupMaxHeight);

  @override
  State<_LspCompletionPopup> createState() => _LspCompletionPopupState();
}

class _LspCompletionPopupState extends State<_LspCompletionPopup> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};

  GlobalKey _keyForIndex(int i) =>
      _rowKeys.putIfAbsent(i, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_ensureSelectionVisible);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_ensureSelectionVisible);
    _scroll.dispose();
    super.dispose();
  }

  void _ensureSelectionVisible() {
    final i = widget.notifier.value.index;
    final ctx = _rowKeys[i]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 80),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CodeAutocompleteEditingValue>(
      valueListenable: widget.notifier,
      builder: (context, value, _) {
        final prompts = value.prompts;
        return ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kPopupMinHeight,
            maxHeight: kPopupMaxHeight,
          ),
          child: SizedBox(
            width: kPopupWidth,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: kPopupBg,
                  border: Border.all(color: kPopupBorder),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black54,
                        blurRadius: 12,
                        offset: Offset(0, 4)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: prompts.length > 4,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: prompts.length,
                      itemBuilder: (context, i) {
                        final p = prompts[i];
                        final type = p is CodeFieldPrompt ? p.type : '';
                        final kind =
                            p is LspKindFieldPrompt ? p.kind : null;
                        final doc =
                            p is LspKindFieldPrompt ? p.documentation : '';
                        return KeyedSubtree(
                          key: _keyForIndex(i),
                          child: popupRow(
                            word: p.word,
                            detail: type,
                            documentation: doc,
                            kind: kind,
                            selected: i == value.index,
                            onTap: () =>
                                widget.onSelected(p.autocomplete),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

