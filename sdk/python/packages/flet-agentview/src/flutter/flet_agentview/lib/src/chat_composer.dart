import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'slash_menu.dart';

/// Chat input composer with keyboard shortcuts and slash command popup.
///
/// Keyboard behavior:
///   Enter          → submit (or select highlighted item)
///   Shift+Enter    → insert newline
///   CMD/Ctrl+Enter → submit
///   Escape         → dismiss slash menu / exit arg phase / clear input
///   Tab            → common-prefix complete, or select highlighted item
///   Arrow Up/Down  → navigate slash menu items
///
/// Two-phase slash menu:
///   Phase 1 (commands): type `/` to see commands, pick one
///   Phase 2 (args): if the command has arg suggestions, show them
///     for the user to pick or type-filter
///
/// The slash menu sits above the input in a Column layout. A GlobalKey on
/// the inputRow prevents TextField unmount/remount (which kills focus)
/// when the menu appears or disappears.
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
  final GlobalKey _inputRowKey = GlobalKey();
  late final FocusNode _focusNode;
  bool _showSlashMenu = false;
  String _slashFilter = '';

  // Two-phase arg selection state
  SlashCommand? _selectedCommand; // non-null = arg phase
  String _argFilter = '';
  int _highlightedIndex = -1; // keyboard-navigated item in slash menu
  final GlobalKey _highlightedItemKey = GlobalKey();

  /// Scroll the slash menu ListView to keep the highlighted item visible.
  /// Two-pass approach: only scrolls if the item is actually off-screen.
  void _scrollToHighlighted() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _highlightedItemKey.currentContext;
      if (ctx == null) return;
      // keepVisibleAtEnd scrolls only if item is below viewport.
      // keepVisibleAtStart scrolls only if item is above viewport.
      // If already visible, neither pass scrolls.
      Scrollable.ensureVisible(ctx,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(ctx,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
  }

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
        _exitArgPhase();
        return KeyEventResult.handled;
      }
      if (_showSlashMenu) {
        _textController.clear();
        setState(() {
          _showSlashMenu = false;
          _slashFilter = '';
          _highlightedIndex = -1;
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Arrow key handling — navigate slash menu items
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && _showSlashMenu) {
      final count = _selectedCommand != null
          ? _filteredArgs().length
          : _filteredCommands().length;
      if (count > 0) {
        setState(() {
          _highlightedIndex = (_highlightedIndex + 1) % count;
        });
        _scrollToHighlighted();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && _showSlashMenu) {
      final count = _selectedCommand != null
          ? _filteredArgs().length
          : _filteredCommands().length;
      if (count > 0) {
        setState(() {
          _highlightedIndex =
              _highlightedIndex <= 0 ? count - 1 : _highlightedIndex - 1;
        });
        _scrollToHighlighted();
      }
      return KeyEventResult.handled;
    }

    // Tab handling — auto-complete or select highlighted item
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (_selectedCommand != null) {
        if (_highlightedIndex >= 0) {
          final filtered = _filteredArgs();
          if (_highlightedIndex < filtered.length) {
            _onSlashArgSelected(filtered[_highlightedIndex]);
          }
        } else {
          _tabCompleteArgs();
        }
        return KeyEventResult.handled;
      }
      if (_showSlashMenu) {
        if (_highlightedIndex >= 0) {
          final filtered = _filteredCommands();
          if (_highlightedIndex < filtered.length) {
            _onSlashCommandSelected(filtered[_highlightedIndex]);
          }
        } else {
          _tabCompleteCommands();
        }
        return KeyEventResult.handled;
      }
      if (_textController.text.startsWith('/')) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Enter handling
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      }
      // In arg phase → select highlighted, best match, or submit as-is
      if (_selectedCommand != null) {
        if (_highlightedIndex >= 0) {
          final filtered = _filteredArgs();
          if (_highlightedIndex < filtered.length) {
            _onSlashArgSelected(filtered[_highlightedIndex]);
            return KeyEventResult.handled;
          }
        }
        final match = _bestArgMatch();
        if (match != null) {
          _onSlashArgSelected(match);
        } else {
          _submit();
        }
        return KeyEventResult.handled;
      }
      // Slash menu: select highlighted or best match, then submit
      if (_showSlashMenu) {
        SlashCommand? cmd;
        if (_highlightedIndex >= 0) {
          final filtered = _filteredCommands();
          if (_highlightedIndex < filtered.length) {
            cmd = filtered[_highlightedIndex];
          }
        }
        cmd ??= _bestSlashMatch();
        if (cmd != null) {
          _textController.text = cmd.command;
          setState(() {
            _showSlashMenu = false;
            _slashFilter = '';
            _selectedCommand = null;
            _argFilter = '';
            _highlightedIndex = -1;
          });
          _submit();
          return KeyEventResult.handled;
        }
      }
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
      _highlightedIndex = -1;
    });
    widget.onSubmit(text);

    // Keep focus on the input after submit
    _focusNode.requestFocus();
  }

  void _onTextChanged(String text) {
    _highlightedIndex = -1; // Reset highlight on any text change
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
      _highlightedIndex = -1;
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

  /// Filtered commands in category order (matches SlashMenu visual layout).
  List<SlashCommand> _filteredCommands() {
    final filtered = widget.slashCommands.where((cmd) {
      final name = cmd.command.substring(1).toLowerCase();
      return name.startsWith(_slashFilter) ||
          cmd.label.toLowerCase().contains(_slashFilter);
    }).toList();

    // Replicate SlashMenu's category grouping order
    final grouped = <String, List<SlashCommand>>{};
    for (final cmd in filtered) {
      final cat = cmd.category ?? '';
      grouped.putIfAbsent(cat, () => []).add(cmd);
    }
    final ordered = <SlashCommand>[];
    for (final cat in slashCategoryOrder) {
      final cmds = grouped.remove(cat);
      if (cmds != null) ordered.addAll(cmds);
    }
    for (final cmds in grouped.values) {
      ordered.addAll(cmds);
    }
    return ordered;
  }

  /// Filtered args for the current command.
  List<SlashArg> _filteredArgs() {
    final argList = _selectedCommand?.args ?? [];
    if (_argFilter.isEmpty) return argList;
    return argList.where((a) {
      return a.value.toLowerCase().contains(_argFilter) ||
          (a.label?.toLowerCase().contains(_argFilter) ?? false);
    }).toList();
  }

  /// Longest common prefix of a list of strings (case-insensitive match).
  static String _longestCommonPrefix(List<String> strings) {
    if (strings.isEmpty) return '';
    var prefix = strings.first;
    for (final s in strings.skip(1)) {
      var i = 0;
      while (i < prefix.length &&
          i < s.length &&
          prefix[i].toLowerCase() == s[i].toLowerCase()) {
        i++;
      }
      prefix = prefix.substring(0, i);
      if (prefix.isEmpty) return '';
    }
    return prefix;
  }

  /// Tab-complete commands: common prefix or select first match.
  void _tabCompleteCommands() {
    final filtered = _filteredCommands();
    if (filtered.isEmpty) return;
    if (filtered.length == 1) {
      _onSlashCommandSelected(filtered.first);
      return;
    }
    // Multiple matches — try common prefix
    final names = filtered.map((c) => c.command.substring(1)).toList();
    final prefix = _longestCommonPrefix(names);
    if (prefix.length > _slashFilter.length) {
      _textController.text = '/$prefix';
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
      setState(() {
        _slashFilter = prefix.toLowerCase();
        _highlightedIndex = -1;
      });
    } else {
      // Can't extend further — select first match
      _onSlashCommandSelected(filtered.first);
    }
  }

  /// Tab-complete args: common prefix or select first match.
  void _tabCompleteArgs() {
    final filtered = _filteredArgs();
    if (filtered.isEmpty) return;
    if (filtered.length == 1) {
      _onSlashArgSelected(filtered.first);
      return;
    }
    final values = filtered.map((a) => a.value).toList();
    final prefix = _longestCommonPrefix(values);
    if (prefix.length > _argFilter.length) {
      _textController.text = '${_selectedCommand!.command} $prefix';
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
      setState(() {
        _argFilter = prefix.toLowerCase();
        _highlightedIndex = -1;
      });
    } else {
      _onSlashArgSelected(filtered.first);
    }
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
        _highlightedIndex = -1;
      });
    } else {
      // No args — auto-submit immediately
      _textController.text = cmd.command;
      setState(() {
        _showSlashMenu = false;
        _slashFilter = '';
        _selectedCommand = null;
        _argFilter = '';
        _highlightedIndex = -1;
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
      _highlightedIndex = -1;
    });
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    final inputRow = Container(
          key: _inputRowKey,
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

    // The slash menu sits above the input in a Column. The GlobalKey on
    // inputRow preserves TextField focus when the menu appears/disappears
    // (prevents unmount/remount when Column children change).
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showSlashMenu)
          Padding(
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
                    highlightedIndex: _highlightedIndex,
                    highlightedItemKey: _highlightedItemKey,
                  )
                : SlashMenu(
                    commands: widget.slashCommands,
                    filter: _slashFilter,
                    onSelected: _onSlashCommandSelected,
                    highlightedIndex: _highlightedIndex,
                    highlightedItemKey: _highlightedItemKey,
                  ),
          ),
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
