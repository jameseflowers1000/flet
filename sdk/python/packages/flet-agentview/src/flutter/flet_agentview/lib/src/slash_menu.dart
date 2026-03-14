import 'package:flutter/material.dart';

import 'models.dart';

/// Category display order and labels for the slash menu.
const _categoryOrder = [
  'navigation',
  'control',
  'code',
  'table',
  'chat',
  'panel',
  'layout',
];

const _categoryLabels = {
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
    for (final cat in _categoryOrder) {
      final cmds = grouped.remove(cat);
      if (cmds == null || cmds.isEmpty) continue;
      final label = _categoryLabels[cat] ?? cat.toUpperCase();
      widgets.add(_buildCategoryHeader(label));
      for (final cmd in cmds) {
        widgets.add(_buildCommandTile(cmd));
      }
    }
    // Any uncategorized commands
    for (final cmds in grouped.values) {
      for (final cmd in cmds) {
        widgets.add(_buildCommandTile(cmd));
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
          constraints: const BoxConstraints(maxHeight: 300, maxWidth: 320),
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

    for (final arg in filtered) {
      widgets.add(_buildArgTile(arg));
    }

    return ExcludeFocus(
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        color: AgentTheme.inputBgColor,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300, maxWidth: 320),
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

  Widget _buildCommandTile(SlashCommand cmd) {
    // Build subtitle: label + optional args_hint
    String subtitle = cmd.label;
    if (cmd.argsHint != null) {
      subtitle = '${cmd.label} · ${cmd.argsHint}';
    }

    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      leading: Icon(
        AgentTheme.getIcon(cmd.icon),
        color: AgentTheme.accentColor,
        size: 16,
      ),
      title: Text(
        cmd.command,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
            color: AgentTheme.mutedTextColor, fontSize: 10),
      ),
      onTap: () => onSelected(cmd),
    );
  }

  Widget _buildArgTile(SlashArg arg) {
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      title: Text(
        arg.value,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      subtitle: arg.label != null && arg.label!.isNotEmpty
          ? Text(
              arg.label!,
              style: const TextStyle(
                  color: AgentTheme.mutedTextColor, fontSize: 10),
            )
          : null,
      onTap: onArgSelected != null ? () => onArgSelected!(arg) : null,
    );
  }
}
