// Floating "help" panel triggered by ⌘K (EZ) or `K` (Vim). Asks the
// LSP server for hover docs at the current cursor and renders them
// in a small overlay near the editor. Both editors share this surface.
//
// When the LSP returns nothing, we fall back to a built-in dictionary
// for the α-paradigm vocabulary so cursoring on `the`/`o`/etc. always
// produces *something* useful, instead of an "ugly no docs" message.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lsp_client.dart';

class HoverPopup {
  static OverlayEntry? _entry;
  static VoidCallback? _onDismissed;
  // True when the panel is showing the "no documentation" / fallback
  // body — in that case any keystroke dismisses (so it doesn't sit
  // on screen while the user keeps typing). For the real-doc case
  // we keep the panel open until Esc / X so the user can read.
  static bool _transient = false;
  static bool _keyHandlerInstalled = false;

  static Future<void> requestAt(
    BuildContext context, {
    required int line,
    required int col,
    required String uri,
    LspClient? lsp,
    VoidCallback? onDismissed,
    /// The token under the cursor at request time, used to look up a
    /// fallback note when the LSP returns nothing.
    String? word,
    /// Caller already ran the LSP probe(s) and got a non-empty body.
    /// Skip the re-fetch when set — we just render this directly.
    String? preFetched,
    /// Caller-supplied fallback dictionary (from `EditorConfig`).
    /// Merged on top of the lab's built-in dictionary so integrators
    /// can add project-specific docs without losing the defaults.
    Map<String, String> extraFallbacks = const {},
  }) async {
    dismiss();
    final overlay = Overlay.of(context, rootOverlay: true);
    String body = '';
    if (preFetched != null && preFetched.isNotEmpty) {
      body = _formatExamples(_stripMarkdownNoise(preFetched));
    } else if (lsp != null) {
      body = _formatExamples(
          _stripMarkdownNoise((await lsp.hover(uri, line, col)).trim()));
    }
    bool transient = false;
    if (body.isEmpty) {
      final fallback = extraFallbacks[word] ?? _localFallback(word);
      if (fallback != null) {
        body = fallback;
      } else {
        body = _emptyNote(word);
        transient = true;
      }
    }
    if (!context.mounted) return;
    _onDismissed = onDismissed;
    _transient = transient;
    if (!_keyHandlerInstalled) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _keyHandlerInstalled = true;
    }
    _entry = OverlayEntry(builder: (_) => _HoverPanel(
          markdown: body,
          onClose: dismiss,
        ));
    overlay.insert(_entry!);
  }

  /// Global keystroke handler. While the panel is on screen:
  ///   - Esc always dismisses (the embedded `Focus(autofocus: true)` +
  ///     `CallbackShortcuts(Escape)` doesn't reliably win focus when
  ///     the EZ editor still holds it, so we catch Esc here too).
  ///   - Any other KeyDown dismisses ONLY for transient (no-doc) bodies.
  /// We claim Esc (return true) so the editor doesn't also act on it,
  /// but pass other keystrokes through so user typing isn't lost.
  static bool _onKey(KeyEvent event) {
    if (_entry == null) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      dismiss();
      return true;
    }
    if (_transient) {
      dismiss();
      return false;
    }
    return false;
  }

  static bool get isOpen => _entry != null;

  static void dismiss() {
    _entry?.remove();
    _entry = null;
    _transient = false;
    if (_keyHandlerInstalled) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _keyHandlerInstalled = false;
    }
    final cb = _onDismissed;
    _onDismissed = null;
    cb?.call();
  }

  /// Lift inline `Example:` (and `Examples:`) to its own line and add
  /// a blank line above so the example stands apart from the prose.
  /// Without this, hover panels often look like:
  ///   "Set the cell background. Example: the.cell.bg = '#FFCC00'"
  /// which crams two unrelated thoughts into one paragraph.
  static String _formatExamples(String s) {
    return s.replaceAllMapped(
      RegExp(r'(?<!\n)\s*([Ee]xample[s]?\s*:)\s*'),
      (m) => '\n\n${m.group(1)}\n  ',
    );
  }

  /// Drop markdown noise that doesn't render meaningfully in a plain
  /// monospace panel: backtick code spans, fenced code blocks, and
  /// bold/italic markers. Header `#` lines are kept (still readable).
  static String _stripMarkdownNoise(String s) {
    // Triple-backtick fenced blocks → inner content as-is.
    s = s.replaceAllMapped(
      RegExp(r'```[a-zA-Z0-9_-]*\n([\s\S]*?)\n?```'),
      (m) => m.group(1) ?? '',
    );
    // Inline backticks → bare contents (we're already monospace).
    s = s.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1) ?? '');
    // Bold (**x** or __x__).
    s = s.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*|__([^_]+)__'),
      (m) => m.group(1) ?? m.group(2) ?? '',
    );
    return s;
  }

  static String _emptyNote(String? word) {
    if (word == null || word.isEmpty) return 'No documentation here.';
    return 'No documentation for $word.';
  }

  /// Fallback notes for the core vocabulary. Tiny and curated; expand
  /// as needed. Keeps `Cmd-K` on common identifiers from being a
  /// dead-end when the LSP can't compute hover (e.g. the cursor is on
  /// a bare identifier rather than a member access).
  static String? _localFallback(String? word) {
    if (word == null || word.isEmpty) return null;
    return _fallbacks[word];
  }

  // Plain-text. The panel renders Menlo monospace, so backticks
  // would be visible noise — see VSCode/IntelliJ which do markdown
  // rendering and convert them to inline-code styling. We don't,
  // so we drop them and rely on the monospace font + indentation.
  static const Map<String, String> _fallbacks = {
    'the':
        'the — the active control.\n\n'
            'Inside any control snippet, the.<member> reaches into the\n'
            'context for the cell, field, or chart you’re currently\n'
            'editing. Common members:\n\n'
            '  the.value         the underlying cell/field value\n'
            '  the.display       what the user sees (often formatted)\n'
            '  the.cell          per-cell context (in ETab snippets)\n'
            '  the.field         per-field context (in EScalar)\n'
            '  the.chart         chart-level context (in EInk plots)\n'
            '  the.is_hovered    true while the pointer is over the control\n'
            '  the.is_focused    true when the control has the keyboard\n'
            '  the.commit        commit the user-visible value\n'
            '  the.cancel        drop a pending edit and revert\n'
            '  the.line(x, y)    add a line series (in plot snippets)\n'
            '  the.title         set the control’s title\n\n'
            'Type the. in the editor to see the full list.',
    'o':
        'o — the document root.\n\n'
            'The active doclet, exposed inside snippets and the REPL as\n'
            'o.<control> (for example o.amort.value or o.summary.code).\n\n'
            'Distinct from the: o reaches outward to other controls;\n'
            'the reaches inward to the current control’s context.',
  };
}

class _HoverPanel extends StatelessWidget {
  final String markdown;
  final VoidCallback onClose;
  const _HoverPanel({required this.markdown, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    return Positioned(
      right: 24,
      top: 80,
      width: 460,
      child: Material(
        color: Colors.transparent,
        // The body is rendered inside a DefaultTextStyle so SelectableText
        // doesn't fall back to Flutter's "no inherited text style" debug
        // indicator (the yellow double underline).
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xFFCCCCCC),
            fontSize: 12,
            fontFamily: 'JetBrainsMono',
            height: 1.45,
            decoration: TextDecoration.none,
          ),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): onClose,
            },
            child: Focus(
              autofocus: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (media.height * 0.7).clamp(160.0, 600.0),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1F1A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF2E3A2A)),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black54,
                          blurRadius: 24,
                          offset: Offset(0, 6)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(onClose: onClose),
                      Flexible(
                        fit: FlexFit.loose,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Text(markdown),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF2E3A2A), width: 1),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.help_outline, color: Color(0xFF97C977), size: 14),
          const SizedBox(width: 6),
          const Text(
            'Documentation',
            style: TextStyle(
              color: Color(0xFFCCCCCC),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              decoration: TextDecoration.none,
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, color: Color(0xFF888888), size: 14),
            ),
          ),
        ],
      ),
    );
  }
}
