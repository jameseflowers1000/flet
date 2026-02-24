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
];

const _categoryLabels = {
  'navigation': 'NAVIGATION',
  'control': 'CONTROLS',
  'code': 'CODE',
  'table': 'TABLE',
  'chat': 'CHAT',
  'panel': 'PANELS',
};

/// Popup menu for slash commands, positioned above the composer input.
///
/// Filters commands based on the current text after '/'.
/// Groups commands by category with small muted headers.
/// Auto-submits on selection (sends the command to Python).
class SlashMenu extends StatelessWidget {
  final List<SlashCommand> commands;
  final String filter;
  final ValueChanged<SlashCommand> onSelected;

  const SlashMenu({
    super.key,
    required this.commands,
    required this.filter,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
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

    return Material(
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
        cmd.label,
        style: const TextStyle(
            color: AgentTheme.mutedTextColor, fontSize: 10),
      ),
      onTap: () => onSelected(cmd),
    );
  }
}
