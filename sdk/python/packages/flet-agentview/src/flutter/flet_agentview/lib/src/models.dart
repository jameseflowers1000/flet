import 'package:flutter/material.dart';

/// A single chat message.
class ChatMessage {
  final String role; // 'user', 'assistant', 'system'
  final String content; // Markdown text
  final String? timestamp;

  const ChatMessage({
    required this.role,
    required this.content,
    this.timestamp,
  });

  bool get isUser => role == 'user' || role == 'request';
}

/// An argument suggestion for a slash command.
class SlashArg {
  final String value; // e.g. 'amort'
  final String? label; // e.g. 'SuperTab'

  const SlashArg({required this.value, this.label});
}

/// A slash command shown in the popup menu.
class SlashCommand {
  final String command; // '/python'
  final String label; // 'Python REPL'
  final String? icon; // Material icon name
  final String? category; // 'navigation', 'control', 'code', 'table', 'chat', 'panel'
  final String? argsHint; // e.g. '<control_name>'
  final List<SlashArg>? args; // argument suggestions from provider

  const SlashCommand({
    required this.command,
    required this.label,
    this.icon,
    this.category,
    this.argsHint,
    this.args,
  });

  /// Whether this command has argument suggestions to show.
  bool get hasArgs => args != null && args!.isNotEmpty;
}

/// Theme constants matching orchestrator.py colors.
class AgentTheme {
  static const bgColor = Color(0xFF1A191F);
  static const inputBgColor = Color(0xFF2A2930);
  static const accentColor = Color(0xFF97C977);
  static const userBubbleColor = Color(0xFF2D4A2D);
  static const assistantBubbleColor = Color(0xFF2A2930);
  static const borderColor = Color(0xFF444444);
  static const textColor = Colors.white;
  static const mutedTextColor = Color(0xFF888888);

  /// Map icon name strings from Python to Material Icons.
  static IconData getIcon(String? name) {
    switch (name) {
      case 'terminal':
        return Icons.terminal;
      case 'code':
        return Icons.code;
      case 'history':
        return Icons.history;
      case 'extension':
        return Icons.extension;
      case 'chat':
        return Icons.chat;
      case 'tune':
        return Icons.tune;
      case 'architecture':
        return Icons.architecture;
      case 'send':
        return Icons.send;
      case 'show_chart':
        return Icons.show_chart;
      case 'center_focus_strong':
        return Icons.center_focus_strong;
      case 'arrow_upward':
        return Icons.arrow_upward;
      case 'place':
        return Icons.place;
      case 'list':
        return Icons.list;
      case 'info':
        return Icons.info;
      case 'edit':
        return Icons.edit;
      case 'delete':
        return Icons.delete;
      case 'view_column':
        return Icons.view_column;
      case 'filter_list':
        return Icons.filter_list;
      case 'table_rows':
        return Icons.table_rows;
      case 'search':
        return Icons.search;
      case 'save':
        return Icons.save;
      case 'delete_sweep':
        return Icons.delete_sweep;
      case 'table_chart':
        return Icons.table_chart;
      case 'close':
        return Icons.close;
      case 'dashboard':
        return Icons.dashboard;
      default:
        return Icons.chevron_right;
    }
  }
}
