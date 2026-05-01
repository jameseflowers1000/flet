import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:flutter_highlight/themes/vs2015.dart';
import 'package:highlight/highlight.dart' show highlight;

import 'color_component.dart';

class MarkdownWidget extends StatelessWidget {
  final Control control;

  const MarkdownWidget({super.key, required this.control});

  @override
  Widget build(BuildContext context) {
    final value = control.getString("value", "")!;
    final darkMode = control.getBool("dark_mode", true)!;
    final codeThemeName = control.getString("code_theme", "atom-one-dark")!;

    final codeTheme = _getCodeTheme(codeThemeName, darkMode);

    final baseStyle = TextStyle(
      color: darkMode ? const Color(0xFFC9D1D9) : const Color(0xFF24292F),
      fontSize: 14,
      height: 1.6,
    );

    return LayoutControl(
      control: control,
      child: SingleChildScrollView(
        child: SelectionArea(
          // ValueKey on the markdown content forces Flutter to remount
          // the GptMarkdown subtree on every value change. Without this
          // key, gpt_markdown caches its parsed AST and doesn't repaint
          // when the parent rebuilds with a new `value` string.
          child: GptMarkdown(
            key: ValueKey(value),
            value,
            style: baseStyle,
            useDollarSignsForLatex: true,
            latexWorkaround: _fixLatexSpacing,
            inlineComponents: [
              ...MarkdownComponent.inlineComponents,
              ColorInlineComponent(),
              SizeInlineComponent(),
              BgInlineComponent(),
              GlowInlineComponent(),
              ShadowInlineComponent(),
              OpacityInlineComponent(),
              FontInlineComponent(),
              SpacingInlineComponent(),
              UnderlineInlineComponent(),
            ],
            codeBuilder: (context, name, code, closed) {
              return _buildCodeBlock(context, name, code, codeTheme, darkMode);
            },
            highlightBuilder: (context, text, style) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: darkMode
                      ? const Color(0xFF343942)
                      : const Color(0xFFEFF1F3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  text,
                  style: style.copyWith(
                    fontFamily: 'monospace',
                    fontSize:
                        style.fontSize != null ? style.fontSize! * 0.9 : 13,
                  ),
                ),
              );
            },
            onLinkTap: (url, title) {
              control.triggerEvent("tap_link", url);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCodeBlock(
    BuildContext context,
    String language,
    String code,
    Map<String, TextStyle> theme,
    bool darkMode,
  ) {
    // Parse and highlight
    List<TextSpan> spans;
    try {
      final result = language.isNotEmpty
          ? highlight.parse(code, language: language)
          : highlight.parse(code, autoDetection: true);
      spans = _convertNodes(result.nodes!, theme);
    } catch (_) {
      spans = [TextSpan(text: code, style: theme['root'])];
    }

    final bgColor = darkMode ? const Color(0xFF1E1E1E) : const Color(0xFFF6F8FA);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectionArea(
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
                color: darkMode
                    ? const Color(0xFFABB2BF)
                    : const Color(0xFF24292F),
              ),
              children: spans,
            ),
          ),
        ),
      ),
    );
  }

  List<TextSpan> _convertNodes(
      List<dynamic> nodes, Map<String, TextStyle> theme) {
    List<TextSpan> spans = [];
    for (var node in nodes) {
      if (node.value != null) {
        spans.add(TextSpan(
          text: node.value,
          style: theme[node.className] ?? theme['root'],
        ));
      } else if (node.children != null) {
        spans.add(TextSpan(
          children: _convertNodes(node.children!, theme),
          style: theme[node.className] ?? theme['root'],
        ));
      }
    }
    return spans;
  }

  /// Add vertical padding to multi-row LaTeX environments (cases, matrix, etc.)
  /// so rows don't crash into each other.
  static String _fixLatexSpacing(String tex) {
    // In cases / pmatrix / bmatrix / vmatrix / array environments,
    // replace bare \\ line breaks with \\[8pt] for vertical breathing room.
    // Only touch \\ that are NOT already followed by [.
    final envPattern = RegExp(
      r'\\begin\{(cases|pmatrix|bmatrix|vmatrix|Vmatrix|matrix|array|aligned|align)\}(.*?)\\end\{\1\}',
      dotAll: true,
    );
    return tex.replaceAllMapped(envPattern, (m) {
      final env = m.group(1)!;
      final body = m.group(2)!;
      // Replace \\ not followed by [ with \\[8pt]
      final spaced = body.replaceAll(RegExp(r'\\\\(?!\[)'), r'\\[8pt]');
      return '\\begin{$env}$spaced\\end{$env}';
    });
  }

  static Map<String, TextStyle> _getCodeTheme(String name, bool darkMode) {
    switch (name.toLowerCase()) {
      case 'atom-one-dark':
        return atomOneDarkTheme;
      case 'atom-one-light':
        return atomOneLightTheme;
      case 'github':
        return githubTheme;
      case 'monokai-sublime':
        return monokaiSublimeTheme;
      case 'vs2015':
        return vs2015Theme;
      default:
        return darkMode ? atomOneDarkTheme : githubTheme;
    }
  }
}
