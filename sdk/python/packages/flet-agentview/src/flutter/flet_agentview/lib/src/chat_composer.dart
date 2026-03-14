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
///   Escape         → dismiss slash menu / exit arg phase / clear input
///
/// Two-phase slash menu:
///   Phase 1 (commands): type `/` to see commands, pick one
///   Phase 2 (args): if the command has arg suggestions, show them
///     for the user to pick or type-filter
///
/// The slash menu renders inline (above the input row in a Column).
/// The Flexible wrapper (here and in the parent AgentView) prevents
/// overflow — the menu shrinks to fit available space.
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

  // Two-phase arg selection state
  SlashCommand? _selectedCommand; // non-null = arg phase
  String _argFilter = '';

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

    // Escape handling
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_selectedCommand != null) {
        // In arg phase → back to command phase
        _exitArgPhase();
        return KeyEventResult.handled;
      }
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

    // Tab handling — auto-complete slash command instead of tab-order navigation
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (_selectedCommand != null) {
        // In arg phase — select best arg match
        final match = _bestArgMatch();
        if (match != null) {
          _onSlashArgSelected(match);
        }
        return KeyEventResult.handled;
      }
      if (_showSlashMenu) {
        final match = _bestSlashMatch();
        if (match != null) {
          _onSlashCommandSelected(match);
        }
        return KeyEventResult.handled;
      }
      // No slash menu — still consume Tab to prevent focus escape
      if (_textController.text.startsWith('/')) {
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
      // In arg phase → select best arg match or submit as-is
      if (_selectedCommand != null) {
        final match = _bestArgMatch();
        if (match != null) {
          _onSlashArgSelected(match);
        } else {
          // Submit as-is (user typed a custom value)
          _submit();
        }
        return KeyEventResult.handled;
      }
      // If slash menu is showing, Enter always submits the command
      // (Tab/space are the triggers for entering arg phase)
      if (_showSlashMenu) {
        final match = _bestSlashMatch();
        if (match != null) {
          _textController.text = match.command;
          setState(() {
            _showSlashMenu = false;
            _slashFilter = '';
            _selectedCommand = null;
            _argFilter = '';
          });
          _submit();
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
      _selectedCommand = null;
      _argFilter = '';
    });
    widget.onSubmit(text);

    // Keep focus on the input after submit
    _focusNode.requestFocus();
  }

  void _onTextChanged(String text) {
    if (_selectedCommand != null) {
      // In arg phase — extract filter text after the command prefix
      final prefix = '${_selectedCommand!.command} ';
      if (text.startsWith(prefix)) {
        setState(() {
          _argFilter = text.substring(prefix.length).toLowerCase();
        });
      } else if (!text.startsWith(_selectedCommand!.command)) {
        // User edited back past the prefix → exit arg phase
        _exitArgPhase();
        // Re-evaluate for command mode
        _evaluateCommandMode(text);
      }
      return;
    }

    _evaluateCommandMode(text);
  }

  void _evaluateCommandMode(String text) {
    if (text.startsWith('/')) {
      // Check for "/command " pattern — exact command match followed by space
      final spaceIdx = text.indexOf(' ');
      if (spaceIdx > 0) {
        final cmdText = text.substring(0, spaceIdx);
        final cmd = widget.slashCommands
            .where((c) => c.command == cmdText)
            .firstOrNull;
        if (cmd != null && cmd.hasArgs) {
          // Enter arg phase with whatever is after the space as filter
          setState(() {
            _selectedCommand = cmd;
            _argFilter = text.substring(spaceIdx + 1).toLowerCase();
            _showSlashMenu = true;
            _slashFilter = '';
          });
          return;
        }
      }
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

  void _exitArgPhase() {
    setState(() {
      _selectedCommand = null;
      _argFilter = '';
      _textController.text = '/';
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
      _slashFilter = '';
      _showSlashMenu = true;
    });
  }

  /// Return the best slash command match for the current filter, or null.
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

  /// Return the best arg match for the current arg filter, or null.
  SlashArg? _bestArgMatch() {
    final argList = _selectedCommand?.args ?? [];
    if (argList.isEmpty) return null;

    final lowerFilter = _argFilter.toLowerCase();
    if (lowerFilter.isEmpty) return null;

    final filtered = argList.where((a) {
      return a.value.toLowerCase().contains(lowerFilter) ||
          (a.label?.toLowerCase().contains(lowerFilter) ?? false);
    }).toList();

    if (filtered.length == 1) return filtered.first;

    // Exact value match
    for (final a in filtered) {
      if (a.value.toLowerCase() == lowerFilter) return a;
    }
    return null;
  }

  void _onSlashCommandSelected(SlashCommand cmd) {
    if (cmd.hasArgs) {
      // Enter arg phase — show arg suggestions
      final prefix = '${cmd.command} ';
      _textController.text = prefix;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: prefix.length),
      );
      setState(() {
        _showSlashMenu = true;
        _slashFilter = '';
        _selectedCommand = cmd;
        _argFilter = '';
      });
    } else {
      // No args — auto-submit immediately
      _textController.text = cmd.command;
      setState(() {
        _showSlashMenu = false;
        _slashFilter = '';
        _selectedCommand = null;
        _argFilter = '';
      });
      _submit();
    }
  }

  void _onSlashArgSelected(SlashArg arg) {
    if (_selectedCommand != null) {
      _textController.text = '${_selectedCommand!.command} ${arg.value}';
    }
    setState(() {
      _showSlashMenu = false;
      _slashFilter = '';
      _selectedCommand = null;
      _argFilter = '';
    });
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    // The slash menu floats above the input row via a Stack so it doesn't
    // push the input/buttons out of the window bounds.
    final inputRow = Container(
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
        );

    // CRITICAL: Always return the same Column structure so the TextField
    // is never unmounted/remounted (which kills focus). The menu slot
    // collapses to zero height when hidden.
    final Widget menuSlot;
    if (_showSlashMenu) {
      menuSlot = Flexible(
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
          child: _selectedCommand != null
              ? SlashMenu(
                  commands: widget.slashCommands,
                  filter: _slashFilter,
                  onSelected: _onSlashCommandSelected,
                  mode: SlashMenuMode.args,
                  args: _selectedCommand!.args,
                  onArgSelected: _onSlashArgSelected,
                  selectedCommandLabel: _selectedCommand!.command,
                  argFilter: _argFilter,
                )
              : SlashMenu(
                  commands: widget.slashCommands,
                  filter: _slashFilter,
                  onSelected: _onSlashCommandSelected,
                ),
        ),
      );
    } else {
      menuSlot = const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        menuSlot,
        inputRow,
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
