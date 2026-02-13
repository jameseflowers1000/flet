import 'package:flutter/material.dart';

import 'models.dart';

/// Popup menu for slash commands, positioned above the composer input.
///
/// Filters commands based on the current text after '/'.
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

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: AgentTheme.inputBgColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: filtered.length,
          itemBuilder: (_, i) {
            final cmd = filtered[i];
            return ListTile(
              dense: true,
              leading: Icon(
                AgentTheme.getIcon(cmd.icon),
                color: AgentTheme.accentColor,
                size: 18,
              ),
              title: Text(
                cmd.command,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: Text(
                cmd.label,
                style: const TextStyle(
                    color: AgentTheme.mutedTextColor, fontSize: 11),
              ),
              onTap: () => onSelected(cmd),
            );
          },
        ),
      ),
    );
  }
}
