// Bridges the async LSP completion request into re_editor's synchronous
// `CodeAutocompletePromptsBuilder.build()` call.
//
// Strategy: keep a per-position cache. When build() is called for a
// (line, column) we don't have results for, kick off an async LSP
// request, return last-known-or-empty for now, and bump a notifier
// when results arrive so the editor rebuilds the popup. Subsequent
// build() calls at the same position return the cached prompts.
library;

import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import 'log.dart';
import 'lsp_client.dart';

class _CacheEntry {
  final int line;
  // The part of the line up to and including the last dot — the
  // anchor for "what completion site this list belongs to". Filter
  // term lives AFTER this and is applied client-side without a fresh
  // request, so the user can keep typing the partial name.
  final String beforeDot;
  List<CodePrompt> prompts;
  _CacheEntry({
    required this.line,
    required this.beforeDot,
    required this.prompts,
  });
}

class LspCompletionPromptsBuilder
    with ChangeNotifier
    implements CodeAutocompletePromptsBuilder {
  final LspClient lsp;
  final String uri;

  // Caller passes a `nudge` callback: invoked after each successful
  // async fetch to ask re_editor to re-run build(). Without this the
  // popup only fires after the user makes ANOTHER buffer edit, since
  // CodeAutocomplete only watches the controller for changes.
  final VoidCallback? nudge;

  // Caller-supplied accessor for the latest full document text and a
  // monotonically increasing version. Each fetch synchronously sends
  // `didChange` with this text BEFORE issuing `completion`, so the
  // server isn't replying based on a stale (debounced) buffer state.
  // Without this, typing `the.` and immediately querying gets back an
  // empty list because the server still sees the pre-`.` buffer.
  final String Function() currentText;
  final int Function() bumpVersion;

  _CacheEntry? _cache;
  Future<void>? _inflight;

  LspCompletionPromptsBuilder({
    required this.lsp,
    required this.uri,
    required this.currentText,
    required this.bumpVersion,
    this.nudge,
  });

  @override
  CodeAutocompleteEditingValue? build(
    BuildContext context,
    CodeLine codeLine,
    CodeLineSelection selection,
  ) {
    final line = selection.endIndex;
    final col = selection.endOffset;
    final fullText = codeLine.text;
    // Suppress completions when the cursor is inside a Python comment
    // or string literal on the current line. Catches the most common
    // cases (a `#` after non-string text, or being mid-string) without
    // a full tokenizer. Triple-quoted strings spanning lines aren't
    // detected here — accepted limitation, those are rare in α code.
    if (_inCommentOrString(fullText, col)) return null;
    final prefix = _wordPrefix(fullText, col);
    // Empty prefix = the cursor is right after a non-word char like
    // `:`, `,`, ` `, `(`, etc., or at the start of the line. Showing
    // completions there is over-eager — pressing Enter would accept
    // the first cached item and produce garbage like
    // `if x == the.cancel:the`. Wait for the user to start typing
    // an identifier (or trigger via `.`) before popping anything.
    if (prefix.isEmpty) return null;

    final cached = _cache;

    // The LSP results are anchored at a specific (line, col, dotted-
    // path-prefix). If any of those moved, the cached prompts are
    // stale — typing past `the.c` and inserting `cell` lands the
    // cursor at `the.cell`, then typing `.` moves to `the.cell.`,
    // which is a NEW completion site that should NOT show the old
    // `the.*` filtered list. Treat as a miss → return null until
    // the new fetch lands and the listener triggers a rebuild.
    final lastDot = prefix.lastIndexOf('.');
    final beforeDot = lastDot >= 0 ? prefix.substring(0, lastDot + 1) : '';
    final filterTerm =
        lastDot >= 0 ? prefix.substring(lastDot + 1) : prefix;

    final hit = cached != null &&
        cached.line == line &&
        cached.beforeDot == beforeDot;

    if (!hit && _inflight == null) {
      // Fetch using the column at the END of `beforeDot` (i.e., right
      // after the last dot, or at the start of the bare word when no
      // dot). Sending the user's CURRENT cursor instead would let the
      // server narrow the response by the partial they've typed —
      // which means backspacing past those chars would leave us with
      // a too-small cached set. With this offset, the server returns
      // ALL children of the dotted chain (or all identifiers for a
      // bare word), and we filter client-side by `filterTerm` as the
      // user types or backspaces within the anchor.
      final wordStart = col - prefix.length;
      final fetchCol = wordStart + (lastDot + 1);
      _inflight = _fetch(line, fetchCol, fullText, beforeDot);
    }
    if (!hit) return null;
    // Safety net: if for any reason the cached prompts ended up empty,
    // don't return a non-null EditingValue — re_editor would still
    // mount the overlay but with no rows, and pressing Tab/Enter on
    // it could trigger an empty-string accept-completion action.
    if (cached.prompts.isEmpty) return null;

    final filtered = filterTerm.isEmpty
        ? cached.prompts
        : cached.prompts
            .where((p) =>
                p.word.toLowerCase().startsWith(filterTerm.toLowerCase()))
            .toList();
    if (filtered.isEmpty) return null;
    // Suppress single-item popup when the filter EXACTLY matches the
    // only candidate — typing `the.buffer` to completion should not
    // pop a one-row "buffer" hint, that's noise. Re-pops the moment
    // the user backspaces or extends.
    if (filtered.length == 1 &&
        filtered.first.word.toLowerCase() == filterTerm.toLowerCase()) {
      return null;
    }
    return CodeAutocompleteEditingValue(
      input: filterTerm,
      prompts: filtered,
      index: 0,
    );
  }

  /// Public hook the editor wires into the controller listener. Each
  /// text change kicks off a prefetch *before* re_editor's 50ms-delayed
  /// build() fires, so the cache is warm by the time it asks. Without
  /// this, build() returns null on the first call and re_editor never
  /// re-asks (it only re-runs build() on actual keyboard events).
  void prefetch(int line, int column, String lineText) {
    if (_inCommentOrString(lineText, column)) return;
    final cached = _cache;
    final prefix = _wordPrefix(lineText, column);
    // Symmetric with build()'s gate — don't even hit the LSP when
    // there's no word/dot prefix at the cursor; popup wouldn't show
    // anyway, no point sending the network round-trip.
    if (prefix.isEmpty) return;
    final lastDot = prefix.lastIndexOf('.');
    final beforeDot = lastDot >= 0 ? prefix.substring(0, lastDot + 1) : '';
    final hit = cached != null &&
        cached.line == line &&
        cached.beforeDot == beforeDot;
    if (hit || _inflight != null) return;
    final wordStart = column - prefix.length;
    final fetchCol = wordStart + (lastDot + 1);
    _inflight = _fetch(line, fetchCol, lineText, beforeDot);
  }

  Future<void> _fetch(
      int line, int column, String lineText, String beforeDot) async {
    try {
      // Force the server to see the buffer as it is RIGHT NOW. The
      // editor's regular `didChange` push is debounced (so rapid keys
      // don't flood); without this sync the completion would race
      // ahead of the latest edit and the server would route based on
      // stale text — the famous "type `the.` get nothing" failure.
      lsp.didChange(uri, currentText(), version: bumpVersion());
      final items = await lsp.completion(uri, line, column);
      // Sort items so subtree-like kinds (Module/Class) cluster at the
      // top, then properties/fields, then leaves. Same flat list a
      // user typing `the.` saw before, but ordered hierarchically so
      // the top of the list is "branches" and the bottom is "leaves"
      // — closer to VSCode/Sublime's grouped feel without forcing a
      // tree-style two-step accept.
      final sorted = [...items];
      sorted.sort((a, b) {
        final pa = kindSortPriority(a.kind);
        final pb = kindSortPriority(b.kind);
        if (pa != pb) return pa.compareTo(pb);
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      final prompts = sorted
          .map((it) => LspKindFieldPrompt(
                word: (it.insertText ?? it.label).trim(),
                type: it.detail ?? '',
                documentation: it.documentation ?? '',
                kind: it.kind,
              ) as CodePrompt)
          .toList();
      _cache = _CacheEntry(
        line: line,
        beforeDot: beforeDot,
        prompts: prompts,
      );
      // Diagnostic: log the first few items so we can see what the
      // server actually sent (helps debug "the popup shows weird text"
      // reports). Comment out once stable.
      final firstFew = items.isEmpty
          ? ''
          : '; first 5: ${items.take(5).map((it) => "${it.label}|insertText=${it.insertText}|detail=${it.detail}").join(" / ")}';
      labLog('[lsp.completion] line=$line col=$column beforeDot="$beforeDot" '
          'got ${items.length} items$firstFew');
      notifyListeners();
      nudge?.call();
    } catch (e) {
      debugPrint('[lsp.completion] error: $e');
    } finally {
      _inflight = null;
    }
  }

  /// True when the cursor at `col` on `line` should NOT pop completions:
  ///   - inside a Python comment (after an unquoted `#`)
  ///   - inside a regular `'…'` / `"…"` string literal
  ///
  /// EXCEPTION: inside an f-string's `{…}` brace, completions ARE
  /// allowed — that's interpolated code and users want bridge access
  /// (e.g. `f"value={the.value}"`).
  ///
  /// Walks the line left→right tracking open-quote, f-string-prefix,
  /// brace-depth, and escape state. Triple-quoted strings spanning
  /// multiple lines aren't covered — that's a tokenizer-level concern;
  /// for inline gating this heuristic catches the common cases.
  bool _inCommentOrString(String line, int col) {
    final n = line.length < col ? line.length : col;
    String? quote; // null = code; else opening quote char
    bool isFString = false; // current quote is an f-string?
    int fBraceDepth = 0; // depth inside f-string interpolation
    for (int i = 0; i < n; i++) {
      final c = line.codeUnitAt(i);
      final ch = String.fromCharCode(c);
      if (quote == null) {
        if (c == 0x23 /* # */) return true;
        if (c == 0x22 /* " */ || c == 0x27 /* ' */) {
          // Look back for an f / F / rf / fr prefix.
          isFString = _hasFStringPrefix(line, i);
          quote = ch;
          fBraceDepth = 0;
        }
      } else if (isFString && fBraceDepth > 0) {
        // Inside an f-string interpolation — treat as CODE.
        if (c == 0x7b /* { */) {
          fBraceDepth++;
        } else if (c == 0x7d /* } */) {
          fBraceDepth--;
        }
        // Comments/quotes nested inside `{...}` get re-tracked via
        // separate state; we don't recurse here. Good enough for typical
        // use (`f"x={obj.attr}"` etc.).
      } else {
        if (c == 0x5c /* \ */ && i + 1 < n) {
          i++; // skip escaped char
          continue;
        }
        if (isFString && c == 0x7b /* { */) {
          // f"…{ … " — entering interpolation. `{{` is a literal `{`
          // and stays in string mode.
          if (i + 1 < n && line.codeUnitAt(i + 1) == 0x7b) {
            i++;
            continue;
          }
          fBraceDepth = 1;
          continue;
        }
        if (ch == quote) {
          quote = null;
          isFString = false;
        }
      }
    }
    // If we ended inside a quote and outside an f-string brace → string.
    if (quote != null && !(isFString && fBraceDepth > 0)) return true;
    return false;
  }

  /// Look backward from index `i` for a Python f-string prefix
  /// (`f`, `F`, `rf`, `Rf`, `fr`, `fR`, etc.). Cheap: just the
  /// 1- or 2-char window before the quote, no full lex.
  bool _hasFStringPrefix(String line, int i) {
    String prev1 = i > 0 ? line[i - 1].toLowerCase() : '';
    String prev2 = i > 1 ? line[i - 2].toLowerCase() : '';
    if (prev1 == 'f') return true;
    if ((prev1 == 'r' && prev2 == 'f') ||
        (prev1 == 'f' && prev2 == 'r')) {
      return true;
    }
    return false;
  }

  String _wordPrefix(String line, int col) {
    if (col <= 0 || col > line.length) return '';
    int i = col;
    while (i > 0) {
      final ch = line.codeUnitAt(i - 1);
      // Word-chars: ascii letters, digits, underscore, dot (so the.fie<>
      // counts the prefix as `the.fie`).
      final isAlpha = (ch >= 0x41 && ch <= 0x5a) || (ch >= 0x61 && ch <= 0x7a);
      final isDigit = ch >= 0x30 && ch <= 0x39;
      if (isAlpha || isDigit || ch == 0x5f /* _ */ || ch == 0x2e /* . */) {
        i--;
      } else {
        break;
      }
    }
    return line.substring(i, col);
  }
}

/// LSP CompletionItemKind → visual ordering priority for the popup.
/// Lower numbers sort first. Modules / Classes are treated as
/// "branches" (subtree heads) and float to the top; bare properties
/// / fields / variables come below; keywords and snippets at the
/// bottom. Items without a kind go to the very bottom (no signal).
///
/// Public so the vim-side popup can apply the same sort the EZ side
/// builds in `_fetch`. Without sharing this, the two popups disagree
/// on order — vim shows the alphabetical raw response (`f annotation,
/// f area, fa axis, …`) while EZ groups branches at the top.
int kindSortPriority(int? kind) {
  switch (kind) {
    case 9: // Module
      return 0;
    case 7: // Class
      return 1;
    case 8: // Interface
      return 2;
    case 22: // Struct
      return 3;
    case 10: // Property
      return 10;
    case 5: // Field
      return 11;
    case 6: // Variable
      return 12;
    case 21: // Constant
      return 13;
    case 12: // Value
      return 14;
    case 2: // Method
      return 20;
    case 3: // Function
      return 21;
    case 14: // Keyword
      return 30;
    case 15: // Snippet
      return 31;
  }
  return 50;
}

/// CodeFieldPrompt + LSP CompletionItemKind so the popup can render
/// the VSCode-style kind glyph alongside the label, plus an optional
/// `documentation` one-liner that fills the third row of the popup.
class LspKindFieldPrompt extends CodeFieldPrompt {
  final int? kind;
  final String documentation;
  const LspKindFieldPrompt({
    required super.word,
    required super.type,
    this.kind,
    this.documentation = '',
  });
}
