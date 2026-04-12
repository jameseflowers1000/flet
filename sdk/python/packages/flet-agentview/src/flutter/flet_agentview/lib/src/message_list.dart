import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:markdown/markdown.dart' as md;

import 'models.dart';

/// Scrollable message list with auto-scroll and empty-state placeholder.
class MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final String placeholderText;
  final String placeholderIcon;
  final Color bgColor;

  const MessageList({
    super.key,
    required this.messages,
    required this.placeholderText,
    this.placeholderIcon = '',
    required this.bgColor,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return _buildPlaceholder();
    }

    // reverse: true — index 0 is the newest message, shown at bottom.
    // The extra item (highest index) is a compact placeholder at the top
    // of the conversation history, so the icon/help text stay accessible.
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: widget.messages.length + 1,
      itemBuilder: (_, index) {
        if (index == widget.messages.length) {
          return _buildCompactPlaceholder();
        }
        final msg = widget.messages[widget.messages.length - 1 - index];
        return _MessageBubble(message: msg);
      },
    );
  }

  Widget _buildCompactPlaceholder() {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.placeholderIcon.isNotEmpty)
              Opacity(
                opacity: 0.4,
                child: Image.memory(
                  base64Decode(widget.placeholderIcon),
                  height: 40,
                  filterQuality: FilterQuality.medium,
                ),
              )
            else
              Icon(Icons.chat_bubble_outline,
                  color: AgentTheme.mutedTextColor.withValues(alpha: 0.4),
                  size: 32),
            const SizedBox(height: 8),
            Text(
              widget.placeholderText,
              style: TextStyle(
                color: AgentTheme.mutedTextColor.withValues(alpha: 0.5),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.placeholderIcon.isNotEmpty)
            Image.memory(
              base64Decode(widget.placeholderIcon),
              height: 64,
              filterQuality: FilterQuality.medium,
            )
          else
            Icon(Icons.chat_bubble_outline,
                color: AgentTheme.mutedTextColor, size: 48),
          const SizedBox(height: 16),
          Text(
            widget.placeholderText,
            style: const TextStyle(
                color: AgentTheme.mutedTextColor, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Individual message bubble with role-based alignment and styling.
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser
              ? AgentTheme.userBubbleColor
              : AgentTheme.assistantBubbleColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: isUser ? _buildUserContent() : _buildAssistantContent(),
      ),
    );
  }

  Widget _buildUserContent() {
    return SelectableText(
      message.content,
      style: const TextStyle(color: AgentTheme.textColor, fontSize: 13),
    );
  }

  Widget _buildAssistantContent() {
    return SelectionArea(
      child: MarkdownBody(
        data: message.content,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        builders: {
          'code': _CodeElementBuilder(_darkCodeTheme),
        },
        styleSheet: _darkMarkdownStyleSheet(),
        shrinkWrap: true,
        fitContent: true,
        softLineBreak: true,
        onTapLink: (text, href, title) {
          // Links handled externally if needed
        },
      ),
    );
  }
}

// ── Markdown styling ──────────────────────────────────────────────────

MarkdownStyleSheet _darkMarkdownStyleSheet() {
  return MarkdownStyleSheet(
    p: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
    h1: const TextStyle(
        color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
    h2: const TextStyle(
        color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
    h3: const TextStyle(
        color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
    h4: const TextStyle(
        color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
    code: const TextStyle(
      color: Color(0xFFE0E0E0),
      backgroundColor: Color(0xFF1E1E2E),
      fontFamily: 'monospace',
      fontSize: 12,
    ),
    codeblockDecoration: BoxDecoration(
      color: const Color(0xFF1E1E2E),
      borderRadius: BorderRadius.circular(8),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    blockquote:
        const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
    blockquoteDecoration: const BoxDecoration(
      border: Border(left: BorderSide(color: Color(0xFF555555), width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
    listBullet: const TextStyle(color: Colors.white, fontSize: 13),
    a: const TextStyle(
        color: AgentTheme.accentColor,
        decoration: TextDecoration.underline),
    strong: const TextStyle(
        color: Colors.white, fontWeight: FontWeight.bold),
    em: const TextStyle(
        color: Colors.white, fontStyle: FontStyle.italic),
    tableHead: const TextStyle(
        color: Colors.white, fontWeight: FontWeight.bold),
    tableBody: const TextStyle(color: Colors.white),
    tableBorder: TableBorder.all(color: const Color(0xFF444444)),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xFF444444))),
    ),
  );
}

// ── Code highlighting ─────────────────────────────────────────────────

/// Simplified code element builder for syntax-highlighted fenced blocks.
class _CodeElementBuilder extends MarkdownElementBuilder {
  final Map<String, TextStyle> codeTheme;

  _CodeElementBuilder(this.codeTheme);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Only handle fenced code blocks (content ends with newline)
    if (!element.textContent.endsWith('\n')) {
      return null;
    }

    var language = '';
    if (element.attributes['class'] != null) {
      final lg = element.attributes['class'] as String;
      if (lg.startsWith('language-')) {
        language = lg.substring(9);
      }
    }

    final source =
        element.textContent.substring(0, element.textContent.length - 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          width: constraints.maxWidth == double.infinity
              ? 10000
              : double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText.rich(
            TextSpan(
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFFE0E0E0),
              ),
              children: _highlightSource(source, language),
            ),
          ),
        );
      },
    );
  }

  List<TextSpan> _highlightSource(String source, String language) {
    try {
      final result = language.isNotEmpty
          ? highlight.parse(source, language: language)
          : highlight.parse(source, autoDetection: true);
      return _convertNodes(result.nodes ?? []);
    } catch (_) {
      return [TextSpan(text: source)];
    }
  }

  List<TextSpan> _convertNodes(List<Node> nodes) {
    final spans = <TextSpan>[];
    for (final node in nodes) {
      if (node.value != null) {
        spans.add(
          node.className == null
              ? TextSpan(text: node.value)
              : TextSpan(text: node.value, style: codeTheme[node.className!]),
        );
      } else if (node.children != null) {
        spans.add(TextSpan(
          children: _convertNodes(node.children!),
          style: codeTheme[node.className!],
        ));
      }
    }
    return spans;
  }
}

/// Minimal dark code theme (VS Code Dark+ inspired).
const _darkCodeTheme = <String, TextStyle>{
  'root': TextStyle(
      color: Color(0xFFE0E0E0), backgroundColor: Color(0xFF1E1E2E)),
  'keyword': TextStyle(color: Color(0xFF569CD6)),
  'built_in': TextStyle(color: Color(0xFF4EC9B0)),
  'type': TextStyle(color: Color(0xFF4EC9B0)),
  'literal': TextStyle(color: Color(0xFF569CD6)),
  'number': TextStyle(color: Color(0xFFB5CEA8)),
  'string': TextStyle(color: Color(0xFFCE9178)),
  'symbol': TextStyle(color: Color(0xFFCE9178)),
  'comment': TextStyle(color: Color(0xFF6A9955)),
  'doctag': TextStyle(color: Color(0xFF608B4E)),
  'meta': TextStyle(color: Color(0xFF9B9B9B)),
  'meta-keyword': TextStyle(color: Color(0xFF569CD6)),
  'meta-string': TextStyle(color: Color(0xFFCE9178)),
  'function': TextStyle(color: Color(0xFFDCDCAA)),
  'title': TextStyle(color: Color(0xFFDCDCAA)),
  'class': TextStyle(color: Color(0xFF4EC9B0)),
  'variable': TextStyle(color: Color(0xFF9CDCFE)),
  'params': TextStyle(color: Color(0xFF9CDCFE)),
  'attr': TextStyle(color: Color(0xFF9CDCFE)),
  'attribute': TextStyle(color: Color(0xFF9CDCFE)),
  'tag': TextStyle(color: Color(0xFF569CD6)),
  'name': TextStyle(color: Color(0xFF569CD6)),
  'selector-tag': TextStyle(color: Color(0xFF569CD6)),
  'selector-id': TextStyle(color: Color(0xFFD7BA7D)),
  'selector-class': TextStyle(color: Color(0xFFD7BA7D)),
  'regexp': TextStyle(color: Color(0xFFD16969)),
  'deletion': TextStyle(color: Color(0xFFCE9178)),
  'addition': TextStyle(color: Color(0xFFB5CEA8)),
  'subst': TextStyle(color: Color(0xFF9CDCFE)),
  'section': TextStyle(color: Color(0xFFDCDCAA)),
  'bullet': TextStyle(color: Color(0xFFD7BA7D)),
  'emphasis': TextStyle(fontStyle: FontStyle.italic),
  'strong': TextStyle(fontWeight: FontWeight.bold),
  'link': TextStyle(color: Color(0xFF569CD6)),
};
