import 'package:flutter/material.dart';

import 'models.dart';

/// Category display order and labels for the slash menu.
const slashCategoryOrder = [
  'context',
  'navigation',
  'control',
  'code',
  'table',
  'chat',
  'panel',
  'layout',
];

const slashCategoryLabels = {
  'context': 'CONTEXT',
  'navigation': 'NAVIGATION',
  'control': 'CONTROLS',
  'code': 'CODE',
  'table': 'TABLE',
  'chat': 'CHAT',
  'panel': 'PANELS',
  'layout': 'LAYOUT',
};

/// Whether the slash menu shows commands or argument suggestions.
enum SlashMenuMode { commands, args }

/// Popup menu for slash commands, positioned above the composer input.
///
/// In [SlashMenuMode.commands] mode: shows categorized slash commands,
/// with optional args_hint in the subtitle.
///
/// In [SlashMenuMode.args] mode: shows a flat filtered list of argument
/// suggestions for the selected command, with a header.
class SlashMenu extends StatelessWidget {
  final List<SlashCommand> commands;
  final String filter;
  final ValueChanged<SlashCommand> onSelected;

  // Arg mode fields
  final SlashMenuMode mode;
  final List<SlashArg>? args;
  final ValueChanged<SlashArg>? onArgSelected;
  final String? selectedCommandLabel;
  final String argFilter;
  final int highlightedIndex;
  final GlobalKey? highlightedItemKey;

  const SlashMenu({
    super.key,
    required this.commands,
    required this.filter,
    required this.onSelected,
    this.mode = SlashMenuMode.commands,
    this.args,
    this.onArgSelected,
    this.selectedCommandLabel,
    this.argFilter = '',
    this.highlightedIndex = -1,
    this.highlightedItemKey,
  });

  @override
  Widget build(BuildContext context) {
    if (mode == SlashMenuMode.args) {
      return _buildArgsMenu();
    }
    return _buildCommandsMenu();
  }

  Widget _buildCommandsMenu() {
    final filtered = commands.where((cmd) {
      final name = cmd.command.substring(1).toLowerCase();
      return name.startsWith(filter) ||
          cmd.label.toLowerCase().contains(filter);
    }).toList();

    if (filtered.isEmpty) return const SizedBox.shrink();

    // Group by category
    final grouped = <String, List<SlashCommand>>{};
    for (final cmd in filtered) {
      final cat = cmd.category ?? '';
      grouped.putIfAbsent(cat, () => []).add(cmd);
    }

    // Build ordered list of widgets (headers + items)
    final widgets = <Widget>[];
    int cmdIdx = 0;
    for (final cat in slashCategoryOrder) {
      final cmds = grouped.remove(cat);
      if (cmds == null || cmds.isEmpty) continue;
      final label = slashCategoryLabels[cat] ?? cat.toUpperCase();
      widgets.add(_buildCategoryHeader(label));
      for (final cmd in cmds) {
        widgets.add(
            _buildCommandTile(cmd, highlighted: cmdIdx == highlightedIndex));
        cmdIdx++;
      }
    }
    // Any uncategorized commands
    for (final cmds in grouped.values) {
      for (final cmd in cmds) {
        widgets.add(
            _buildCommandTile(cmd, highlighted: cmdIdx == highlightedIndex));
        cmdIdx++;
      }
    }

    // ExcludeFocus prevents the menu from stealing keyboard focus
    // from the composer TextField when it appears.
    return ExcludeFocus(
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        color: AgentTheme.inputBgColor,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400, maxWidth: 320),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: widgets,
          ),
        ),
      ),
    );
  }

  Widget _buildArgsMenu() {
    final argList = args ?? [];
    final lowerFilter = argFilter.toLowerCase();
    final filtered = lowerFilter.isEmpty
        ? argList
        : argList.where((a) {
            return a.value.toLowerCase().contains(lowerFilter) ||
                (a.label?.toLowerCase().contains(lowerFilter) ?? false);
          }).toList();

    if (filtered.isEmpty) return const SizedBox.shrink();

    final widgets = <Widget>[];

    // Header showing which command we're picking args for
    if (selectedCommandLabel != null) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(left: 16, top: 6, bottom: 4, right: 16),
        child: Text(
          selectedCommandLabel!,
          style: TextStyle(
            color: AgentTheme.accentColor,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ));
    }

    int argIdx = 0;
    for (final arg in filtered) {
      widgets.add(
          _buildArgTile(arg, highlighted: argIdx == highlightedIndex));
      argIdx++;
    }

    return ExcludeFocus(
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        color: AgentTheme.inputBgColor,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400, maxWidth: 320),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: widgets,
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 8, bottom: 2),
      child: Text(
        label,
        style: TextStyle(
          color: AgentTheme.mutedTextColor.withValues(alpha: 0.7),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildCommandTile(SlashCommand cmd, {bool highlighted = false}) {
    // Build subtitle: label + optional args_hint
    String subtitle = cmd.label;
    if (cmd.argsHint != null) {
      subtitle = '${cmd.label} · ${cmd.argsHint}';
    }

    return ListTile(
      key: highlighted ? highlightedItemKey : null,
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      selected: highlighted,
      selectedTileColor: AgentTheme.accentColor.withValues(alpha: 0.15),
      leading: Icon(
        AgentTheme.getIcon(cmd.icon),
        color: AgentTheme.accentColor,
        size: 16,
      ),
      title: Text(
        cmd.command,
        style: TextStyle(
          color: highlighted ? AgentTheme.accentColor : Colors.white,
          fontSize: 12,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: highlighted
              ? AgentTheme.accentColor.withValues(alpha: 0.7)
              : AgentTheme.mutedTextColor,
          fontSize: 10,
        ),
      ),
      onTap: () => onSelected(cmd),
    );
  }

  Widget _buildArgTile(SlashArg arg, {bool highlighted = false}) {
    return ListTile(
      key: highlighted ? highlightedItemKey : null,
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      selected: highlighted,
      selectedTileColor: AgentTheme.accentColor.withValues(alpha: 0.15),
      title: Text(
        arg.value,
        style: TextStyle(
          color: highlighted ? AgentTheme.accentColor : Colors.white,
          fontSize: 12,
        ),
      ),
      subtitle: arg.label != null && arg.label!.isNotEmpty
          ? Text(
              arg.label!,
              style: TextStyle(
                color: highlighted
                    ? AgentTheme.accentColor.withValues(alpha: 0.7)
                    : AgentTheme.mutedTextColor,
                fontSize: 10,
              ),
            )
          : null,
      onTap: onArgSelected != null ? () => onArgSelected!(arg) : null,
    );
  }
}
