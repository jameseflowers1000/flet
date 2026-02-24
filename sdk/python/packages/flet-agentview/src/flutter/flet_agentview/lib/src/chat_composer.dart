import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'slash_menu.dart';

/// Chat input composer with keyboard shortcuts and slash command popup.
///
/// Keyboard behavior:
///   Enter          → submit
///   Shift+Enter    → insert newline
///   CMD/Ctrl+Enter → submit
///   Escape         → dismiss slash menu + clear input
///
/// The slash menu renders inline (above the input row in a Column),
/// avoiding Overlay positioning issues in the Flet framework.
class ChatComposer extends StatefulWidget {
  final String hintText;
  final List<SlashCommand> slashCommands;
  final ValueChanged<String> onSubmit;
  final FocusNode? focusNode;
  final String modeLabel;
  final String modeIcon;
  final List<Map<String, dynamic>> breadcrumb;
  final ValueChanged<int>? onBreadcrumbTap;

  const ChatComposer({
    super.key,
    required this.hintText,
    required this.slashCommands,
    required this.onSubmit,
    this.focusNode,
    this.modeLabel = '',
    this.modeIcon = '',
    this.breadcrumb = const [],
    this.onBreadcrumbTap,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final TextEditingController _textController = TextEditingController();
  late final FocusNode _focusNode;
  bool _showSlashMenu = false;
  String _slashFilter = '';

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.onKeyEvent = _handleKeyEvent;
  }

  @override
  void dispose() {
    _textController.dispose();
    // Only dispose if we created it
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Escape → dismiss slash menu and clear input
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_showSlashMenu) {
        _textController.clear();
        setState(() {
          _showSlashMenu = false;
          _slashFilter = '';
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Enter handling
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      // Shift+Enter → insert newline (let TextField handle it)
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      }
      // If slash menu is showing, auto-select the best match
      if (_showSlashMenu) {
        final match = _bestSlashMatch();
        if (match != null) {
          _onSlashCommandSelected(match);
          return KeyEventResult.handled;
        }
      }
      // Bare Enter or CMD/Ctrl+Enter → submit
      _submit();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _submit() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();
    setState(() {
      _showSlashMenu = false;
      _slashFilter = '';
    });
    widget.onSubmit(text);

    // Keep focus on the input after submit
    _focusNode.requestFocus();
  }

  void _onTextChanged(String text) {
    if (text.startsWith('/')) {
      setState(() {
        _slashFilter = text.substring(1).toLowerCase();
        _showSlashMenu = true;
      });
    } else if (_showSlashMenu) {
      setState(() {
        _showSlashMenu = false;
        _slashFilter = '';
      });
    }
  }

  /// Return the best slash command match for the current filter, or null.
  ///
  /// If there's exactly one match, return it. If the filter is an exact
  /// command name (minus the slash), return that. Otherwise null — let the
  /// user pick from the menu.
  SlashCommand? _bestSlashMatch() {
    final filtered = widget.slashCommands.where((cmd) {
      final name = cmd.command.substring(1).toLowerCase();
      return name.startsWith(_slashFilter) ||
          cmd.label.toLowerCase().contains(_slashFilter);
    }).toList();

    if (filtered.length == 1) return filtered.first;

    // Exact match takes priority even among multiple results
    for (final cmd in filtered) {
      if (cmd.command.substring(1).toLowerCase() == _slashFilter) {
        return cmd;
      }
    }
    return null;
  }

  void _onSlashCommandSelected(SlashCommand cmd) {
    _textController.text = cmd.command;
    setState(() {
      _showSlashMenu = false;
      _slashFilter = '';
    });
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Slash menu sits directly above the input row
        if (_showSlashMenu)
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
            child: SlashMenu(
              commands: widget.slashCommands,
              filter: _slashFilter,
              onSelected: _onSlashCommandSelected,
            ),
          ),
        // Input row
        Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            border: Border(
                top: BorderSide(color: AgentTheme.borderColor, width: 0.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Mode icon (base64 image) when present
              if (widget.modeIcon.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Image.memory(
                    base64Decode(widget.modeIcon),
                    height: 44,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              // Breadcrumb bar — clickable segments separated by " > "
              if (widget.breadcrumb.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: _BreadcrumbBar(
                    breadcrumb: widget.breadcrumb,
                    onTap: widget.onBreadcrumbTap,
                  ),
                )
              // Fallback: mode label chip for non-default modes (no breadcrumb)
              else if (widget.modeIcon.isEmpty &&
                  widget.modeLabel.isNotEmpty &&
                  widget.modeLabel.toLowerCase() != 'general')
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AgentTheme.accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AgentTheme.accentColor.withValues(alpha: 0.4),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      widget.modeLabel,
                      style: TextStyle(
                        color: AgentTheme.accentColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _focusNode,
                  maxLines: 5,
                  minLines: 1,
                  onChanged: _onTextChanged,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    hintStyle: const TextStyle(
                        color: AgentTheme.mutedTextColor, fontSize: 13),
                    filled: true,
                    fillColor: AgentTheme.inputBgColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  cursorColor: AgentTheme.accentColor,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                color: AgentTheme.accentColor,
                iconSize: 20,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Clickable breadcrumb bar showing context stack navigation.
///
/// Each segment is a tappable chip; tapping calls [onTap] with the
/// segment's depth index, which pops the context stack to that level.
class _BreadcrumbBar extends StatelessWidget {
  final List<Map<String, dynamic>> breadcrumb;
  final ValueChanged<int>? onTap;

  const _BreadcrumbBar({required this.breadcrumb, this.onTap});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (int i = 0; i < breadcrumb.length; i++) {
      final segment = breadcrumb[i];
      final label = segment['label'] as String? ?? '';
      final isLast = i == breadcrumb.length - 1;

      if (i > 0) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            '>',
            style: TextStyle(
              color: AgentTheme.mutedTextColor,
              fontSize: 10,
            ),
          ),
        ));
      }

      children.add(
        GestureDetector(
          onTap: onTap != null ? () => onTap!(i) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isLast
                  ? AgentTheme.accentColor.withValues(alpha: 0.15)
                  : AgentTheme.inputBgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isLast
                    ? AgentTheme.accentColor.withValues(alpha: 0.4)
                    : AgentTheme.borderColor.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isLast ? AgentTheme.accentColor : AgentTheme.mutedTextColor,
                fontSize: 10,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }
}
