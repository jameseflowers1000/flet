// Completion popup for the Vim view — Flutter overlay rendered on
// top of the WebView, fed by the same pygls LSP that powers EZ.
//
// Why not nvim-cmp / coc.nvim? Both require nvim plugins, but our
// nvim is started with `-u NONE --noplugin` for a clean sandbox.
// Loading plugins would mean a full plugin manager (lazy.nvim) and
// all its dependencies inside the lab — heavy. The lab already has
// the LSP client, an overlay surface, and the cursor/line APIs;
// reusing them gives identical α-aware completions in Vim.
//
// Trigger logic mirrors EZ: pop after typing word chars or `.`,
// suppress in comments / strings (except inside f-string `{...}`).
// Tab/Enter/Ctrl-y accepts; Esc dismisses. Up/Down move selection.
import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'log.dart';
import 'lsp_client.dart';
import 'lsp_completion_provider.dart' show kindSortPriority;

// Shared popup palette — matches the editor chrome's sage-green accent
// and is exported so the EZ-side popup can reuse the same constants.
// Selection contrast: muted green text → bright green text (no inverted
// background), so the selected row stays readable.
const Color kPopupBg = Color(0xFF1B1F1A);
const Color kPopupBorder = Color(0xFF2E3A2A);
const Color kPopupFg = Color(0xFFCCCCCC);
const Color kPopupDetailFg = Color(0xFF7E9F70); // muted green for type hint
const Color kPopupSelectedBg = Color(0xFF2E4A1F); // darker sage band
const Color kPopupSelectedFg = Color(0xFFD7F0BA); // bright sage label
const Color kPopupSelectedDetailFg = Color(0xFFB6D69E);
const double kPopupFontSize = 13;
const double kPopupDetailFontSize = 11;
// Variable-height rows: the doc line wraps onto as many lines as it
// needs. We cap the popup at kPopupMaxHeight pixels (scrollable past
// that). No fixed itemExtent — each row sizes to its content.
const double kPopupMaxHeight = 520;
const double kPopupMinHeight = 40;
const double kPopupWidth = 480;

/// Map LSP CompletionItemKind → a 1-character glyph + color, in the
/// spirit of VSCode/Sublime's kind icons. Returns null when we don't
/// have a meaningful classification (item shows without an icon).
({String glyph, Color color})? popupKindGlyph(int? kind) {
  switch (kind) {
    case 2: // Method
    case 3: // Function
      return (glyph: 'ƒ', color: Color(0xFF61AFEF));
    case 5: // Field
      return (glyph: '◆', color: Color(0xFFD19A66));
    case 6: // Variable
      return (glyph: 'v', color: Color(0xFFCCCCCC));
    case 7: // Class
      return (glyph: 'C', color: Color(0xFFE5C07B));
    case 9: // Module
      return (glyph: 'M', color: Color(0xFFC678DD));
    case 10: // Property
      return (glyph: '●', color: Color(0xFF98C379));
    case 12: // Value
      return (glyph: 'v', color: Color(0xFF56B6C2));
    case 14: // Keyword
      return (glyph: 'k', color: Color(0xFFC678DD));
    case 15: // Snippet
      return (glyph: '⌘', color: Color(0xFF61AFEF));
    case 21: // Constant
      return (glyph: 'c', color: Color(0xFFD19A66));
  }
  return null;
}

/// One popup row — three-line layout: label on top, kind/type on the
/// second line, one-liner doc on the third (when present). Variable
/// content but fixed row height so ListView.builder can keep using
/// `itemExtent`. Long doc wraps onto two visual lines via softWrap.
Widget popupRow({
  required String word,
  required String detail,
  String documentation = '',
  required int? kind,
  required bool selected,
  required VoidCallback onTap,
}) {
  final fg = selected ? kPopupSelectedFg : kPopupFg;
  final detailFg = selected ? kPopupSelectedDetailFg : kPopupDetailFg;
  final kindInfo = popupKindGlyph(kind);
  // The LSP server sometimes packs a multi-line summary into the
  // `detail` field (e.g. "Chart\nBuild a plot - add series ..."). If
  // there's a newline and we have nothing else for documentation,
  // split: first line stays as type, rest becomes the doc summary.
  if (documentation.isEmpty && detail.contains('\n')) {
    final parts = detail.split('\n');
    detail = parts.first;
    documentation = parts.skip(1).join('\n').trim();
  }
  // Lift inline `Example:` to its own line (and put a blank line
  // above it) so multi-line examples in the row read cleanly. Same
  // treatment the Cmd-K hover panel applies; necessary here too now
  // that the row has variable height.
  documentation = documentation.replaceAllMapped(
    RegExp(r'(?<!\n)\s*([Ee]xample[s]?\s*:)\s*'),
    (m) => '\n\n${m.group(1)}\n  ',
  );
  return InkWell(
    onTap: onTap,
    child: Container(
      color: selected ? kPopupSelectedBg : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            height: 18,
            child: kindInfo == null
                ? null
                : Center(
                    child: Text(
                      kindInfo.glyph,
                      style: TextStyle(
                        color: kindInfo.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  word,
                  style: TextStyle(
                    color: fg,
                    fontSize: kPopupFontSize,
                    fontFamily: 'JetBrainsMono',
                    height: 1.15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: TextStyle(
                      color: detailFg,
                      fontSize: kPopupDetailFontSize,
                      fontFamily: 'JetBrainsMono',
                      height: 1.15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (documentation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      documentation,
                      style: TextStyle(
                        color: detailFg,
                        fontSize: kPopupDetailFontSize,
                        fontFamily: 'JetBrainsMono',
                        height: 1.25,
                      ),
                      // Wrap freely — row height grows to fit. Long
                      // doc strings (candle/candlestick/cancel etc.)
                      // are no longer truncated; the popup itself
                      // scrolls if total content exceeds kPopupMaxHeight.
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class VimCompletionPopup {
  static OverlayEntry? _entry;
  static _PopupState? _state;

  /// Open or replace the popup with completions from `lsp` for the
  /// (line, col) cursor position in `uri`. `acceptText` is invoked
  /// with the chosen completion's word so the caller can splice it
  /// into the buffer (e.g. via `nvim_input`).
  static Future<void> show({
    required BuildContext context,
    required LspClient lsp,
    required String uri,
    required int line,
    required int col,
    required String filterTerm,
    required void Function(String accepted, String filterTerm) onAccept,
    /// Screen-pixel offset of the line right BELOW the current cursor
    /// (i.e. row × cellH baseline + cellH). The popup's top-left
    /// anchors to this point so it visually attaches to the cursor.
    Offset? anchorScreenTopLeft,
  }) async {
    final raw = await lsp.completion(uri, line, col);
    // Sort by LSP CompletionItemKind so subtree-like branches
    // (Module/Class) cluster at the top — same ordering the EZ side
    // builds, so the two popups agree.
    final items = [...raw]
      ..sort((a, b) {
        final pa = kindSortPriority(a.kind);
        final pb = kindSortPriority(b.kind);
        if (pa != pb) return pa.compareTo(pb);
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    labLog('[vim.complete] show: lsp returned ${items.length} items '
        'for line=$line col=$col filter="$filterTerm" '
        'mounted=${context.mounted}');
    if (!context.mounted) return;
    if (items.isEmpty) {
      dismiss();
      return;
    }
    final filtered = filterTerm.isEmpty
        ? items
        : items
            .where((it) =>
                (it.insertText ?? it.label)
                    .toLowerCase()
                    .startsWith(filterTerm.toLowerCase()))
            .toList();
    labLog('[vim.complete] show: ${filtered.length} after filtering by '
        '"$filterTerm" (entry=${_entry != null} state=${_state != null})');
    if (filtered.isEmpty) {
      dismiss();
      return;
    }
    if (_entry == null || _state == null) {
      final state = _PopupState(
        items: filtered,
        filterTerm: filterTerm,
        anchorScreenTopLeft: anchorScreenTopLeft,
      );
      _state = state;
      _entry = OverlayEntry(
        builder: (_) => _PopupBody(
          state: state,
          onAccept: (item) {
            final word = (item.insertText ?? item.label).trim();
            onAccept(word, filterTerm);
            dismiss();
          },
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    } else {
      _state!.update(filtered, filterTerm,
          anchorScreenTopLeft: anchorScreenTopLeft);
    }
  }

  /// Move selection up/down — caller wires Ctrl-N / Ctrl-P (or
  /// Up/Down if intercepted) into this. Returns true if the popup
  /// is open and consumed the event.
  static bool moveSelection(int delta) {
    final s = _state;
    if (s == null) return false;
    s.moveBy(delta);
    return true;
  }

  /// Accept the currently selected item — caller wires Tab / Enter.
  /// Returns the accepted word, or null if the popup wasn't open.
  static ({String word, String filterTerm})? acceptCurrent() {
    final s = _state;
    if (s == null) return null;
    final item = s.items[s.index];
    final word = (item.insertText ?? item.label).trim();
    final ft = s.filterTerm;
    dismiss();
    return (word: word, filterTerm: ft);
  }

  static bool get isOpen => _entry != null;

  static void dismiss() {
    _entry?.remove();
    _entry = null;
    _state = null;
  }
}

class _PopupState extends ChangeNotifier {
  List<LspCompletionItem> items;
  String filterTerm;
  Offset? anchorScreenTopLeft;
  int index = 0;
  _PopupState({
    required this.items,
    required this.filterTerm,
    this.anchorScreenTopLeft,
  });

  void update(List<LspCompletionItem> newItems, String newFilter,
      {Offset? anchorScreenTopLeft}) {
    items = newItems;
    filterTerm = newFilter;
    if (anchorScreenTopLeft != null) {
      this.anchorScreenTopLeft = anchorScreenTopLeft;
    }
    if (index >= items.length) index = items.length - 1;
    if (index < 0) index = 0;
    notifyListeners();
  }

  void moveBy(int delta) {
    if (items.isEmpty) return;
    index = (index + delta).clamp(0, items.length - 1);
    notifyListeners();
  }
}

class _PopupBody extends StatefulWidget {
  final _PopupState state;
  final void Function(LspCompletionItem item) onAccept;
  const _PopupBody({required this.state, required this.onAccept});

  @override
  State<_PopupBody> createState() => _PopupBodyState();
}

class _PopupBodyState extends State<_PopupBody> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_ensureSelectionVisible);
  }

  @override
  void dispose() {
    widget.state.removeListener(_ensureSelectionVisible);
    _scroll.dispose();
    super.dispose();
  }

  // Per-row keys so we can call Scrollable.ensureVisible on the
  // currently-selected row when the user navigates with Ctrl-N/P.
  // Variable row heights mean we can't use a fixed-pitch jumpTo.
  final Map<int, GlobalKey> _rowKeys = {};

  GlobalKey _keyForIndex(int i) =>
      _rowKeys.putIfAbsent(i, () => GlobalKey());

  void _ensureSelectionVisible() {
    final i = widget.state.index;
    final ctx = _rowKeys[i]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5, // center if possible
      duration: const Duration(milliseconds: 80),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final onAccept = widget.onAccept;
        final items = state.items;
        final media = MediaQuery.of(context).size;
        Offset anchor = state.anchorScreenTopLeft ??
            Offset(24, media.height - kPopupMaxHeight - 56);
        if (anchor.dx + kPopupWidth > media.width - 8) {
          anchor = Offset(media.width - kPopupWidth - 8, anchor.dy);
        }
        // Cap on the bottom — the popup will scroll inside this height.
        final maxH = math.min(kPopupMaxHeight, media.height - anchor.dy - 8);
        return Positioned(
          left: anchor.dx,
          top: anchor.dy,
          width: kPopupWidth,
          // Outer constraint only — actual height is intrinsic-up-to-max.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: kPopupMinHeight,
              maxHeight: math.max(kPopupMinHeight, maxH),
            ),
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
                  thumbVisibility: items.length > 4,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final it = items[i];
                      return KeyedSubtree(
                        key: _keyForIndex(i),
                        child: popupRow(
                          word: (it.insertText ?? it.label).trim(),
                          detail: it.detail ?? '',
                          documentation: it.documentation ?? '',
                          kind: it.kind,
                          selected: i == state.index,
                          onTap: () => onAccept(it),
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

/// Convenience: extract the typed-prefix word ending at `(line, col)`
/// in `lineText`, walking back through alpha/digit/underscore chars
/// only — same shape as EZ's _wordPrefix but exposed here for the
/// vim-side trigger detection.
String vimWordPrefix(String line, int col) {
  if (col <= 0 || col > line.length) return '';
  int i = col;
  while (i > 0) {
    final c = line.codeUnitAt(i - 1);
    final isAlpha =
        (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    final isDigit = c >= 0x30 && c <= 0x39;
    if (isAlpha || isDigit || c == 0x5f /* _ */ || c == 0x2e /* . */) {
      i--;
    } else {
      break;
    }
  }
  return line.substring(i, col);
}

/// Exported so callers can probe "is the cursor a place we should
/// pop completions?" without depending on this file's private state.
bool vimShouldComplete(String line, int col) {
  final prefix = vimWordPrefix(line, col);
  if (prefix.isEmpty) {
    // Empty word prefix is normally not a completion site — EXCEPT a call-arg
    // position: the char before the cursor (skipping spaces) is '(' or ','.
    // There the server offers the call's keyword args (for `the.Row(` those
    // are the table's columns), so the user can browse them without typing.
    int j = col - 1;
    while (j >= 0 && j < line.length && line[j] == ' ') {
      j--;
    }
    if (!(j >= 0 && j < line.length && (line[j] == '(' || line[j] == ','))) {
      return false;
    }
    // fall through to the string/comment guard below
  }
  // Don't trigger inside strings/comments — same heuristic as EZ.
  // (Slimmer here; EZ has the f-string-aware version.)
  String? quote;
  for (int i = 0; i < col && i < line.length; i++) {
    final c = line[i];
    if (quote == null) {
      if (c == '#') return false;
      if (c == "'" || c == '"' || c == '`') quote = c;
    } else if (c == quote) {
      quote = null;
    }
  }
  if (quote != null) return false;
  return true;
}

