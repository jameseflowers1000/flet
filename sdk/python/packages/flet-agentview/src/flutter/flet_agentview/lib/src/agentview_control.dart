import 'dart:async';
import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

import 'chat_composer.dart';
import 'message_list.dart';
import 'models.dart';

/// AgentView control — custom chat widget replacing Syncfusion SfAIAssistView.
///
/// Reads configuration from Python via control properties.
/// Sends user input back to Python via FletBackend.triggerControlEvent().
class AgentViewControl extends StatefulWidget {
  static const String version = '0.3.0';

  final Control control;

  const AgentViewControl({
    super.key,
    required this.control,
  });

  @override
  State<AgentViewControl> createState() => _AgentViewControlState();
}

class _AgentViewControlState extends State<AgentViewControl> {
  final List<ChatMessage> _messages = [];
  List<SlashCommand> _slashCommands = [];
  bool _versionSent = false;
  bool _wasActive = false;

  // FocusNode owned here, passed down to ChatComposer
  final FocusNode _composerFocusNode = FocusNode();

  // Periodic timer that reclaims focus until Flet's update cycle settles
  Timer? _focusClaimTimer;

  // Theme
  Color _bgColor = const Color(0xFF1A191F);
  String _placeholderText = 'How can epyx help you?';
  String _inputHint = 'Ask something...';
  String _modeLabel = '';
  String _modeIcon = '';
  List<Map<String, dynamic>> _breadcrumb = [];

  @override
  void initState() {
    super.initState();
    _parseConfig();
  }

  @override
  void dispose() {
    _focusClaimTimer?.cancel();
    _composerFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AgentViewControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseConfig();
  }

  void _parseConfig() {
    // Parse messages from Python
    final messagesJson = widget.control.getString("messages");
    if (messagesJson != null && messagesJson.isNotEmpty) {
      try {
        final List<dynamic> msgList = jsonDecode(messagesJson);
        _messages.clear();
        for (final msg in msgList) {
          _messages.add(ChatMessage(
            role: msg['role'] as String? ?? 'user',
            content: msg['content'] as String? ?? '',
            timestamp: msg['timestamp'] as String?,
          ));
        }
      } catch (e) {
        debugPrint('[AgentView] ERROR parsing messages: $e');
      }
    }

    // Parse slash commands from Python
    final slashJson = widget.control.getString("slash_commands");
    if (slashJson != null && slashJson.isNotEmpty) {
      try {
        final List<dynamic> cmdList = jsonDecode(slashJson);
        _slashCommands = cmdList
            .map((c) => SlashCommand(
                  command: c['command'] as String? ?? '',
                  label: c['label'] as String? ?? '',
                  icon: c['icon'] as String?,
                  category: c['category'] as String?,
                  argsHint: c['args_hint'] as String?,
                  args: (c['args'] as List<dynamic>?)
                      ?.map((a) => SlashArg(
                            value: a['value'] as String? ?? '',
                            label: a['label'] as String?,
                          ))
                      .toList(),
                ))
            .toList();
      } catch (e) {
        debugPrint('[AgentView] ERROR parsing slash_commands: $e');
      }
    }

    // Parse context breadcrumb from Python
    final breadcrumbJson = widget.control.getString("context_breadcrumb");
    if (breadcrumbJson != null && breadcrumbJson.isNotEmpty) {
      try {
        final List<dynamic> bcList = jsonDecode(breadcrumbJson);
        _breadcrumb = bcList
            .map((b) => Map<String, dynamic>.from(b as Map))
            .toList();
      } catch (e) {
        debugPrint('[AgentView] ERROR parsing context_breadcrumb: $e');
        _breadcrumb = [];
      }
    } else {
      _breadcrumb = [];
    }

    // Parse UI config
    final bg = widget.control.getString("theme_bg");
    if (bg != null && bg.startsWith('#')) {
      String hex = bg.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      _bgColor = Color(int.parse(hex, radix: 16));
    }

    final placeholder = widget.control.getString("placeholder_text");
    if (placeholder != null && placeholder.isNotEmpty) {
      _placeholderText = placeholder;
    }

    final hint = widget.control.getString("input_hint");
    if (hint != null && hint.isNotEmpty) {
      _inputHint = hint;
    }

    _modeLabel = widget.control.getString("mode_label") ?? '';
    _modeIcon = widget.control.getString("mode_icon") ?? '';

    // Focus management: reclaim focus periodically until settled.
    // Flet's update cycle can steal focus via cascading WebSocket updates,
    // so we keep re-requesting for up to 3s after becoming active.
    // We only stop early once focus has been held stably for 500ms.
    final active = widget.control.getBool("active", true) ?? true;
    if (active && !_wasActive) {
      _startFocusClaim();
    } else if (!active && _wasActive) {
      _focusClaimTimer?.cancel();
      _focusClaimTimer = null;
    }
    _wasActive = active;
  }

  void _startFocusClaim() {
    _focusClaimTimer?.cancel();
    var attempts = 0;
    var stableCount = 0; // consecutive ticks with focus held
    _focusClaimTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      attempts++;
      if (!mounted || attempts > 30) { // 3 seconds max
        timer.cancel();
        _focusClaimTimer = null;
        return;
      }
      if (_composerFocusNode.hasFocus) {
        stableCount++;
        if (stableCount >= 5) { // 500ms of stable focus → done
          timer.cancel();
          _focusClaimTimer = null;
        }
      } else {
        stableCount = 0;
        _composerFocusNode.requestFocus();
      }
    });
  }

  void _onSubmit(String text) {
    if (text.isEmpty) return;

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
    });

    // Send the request text back to Python
    FletBackend.of(context).triggerControlEvent(
      widget.control,
      "request",
      text,
    );
  }

  void _onContextNav(int depth) {
    FletBackend.of(context).triggerControlEvent(
      widget.control,
      "context_nav",
      depth.toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Send version to Python once
    if (!_versionSent) {
      _versionSent = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FletBackend.of(context).updateControl(
          widget.control.id,
          {'runtime_version': AgentViewControl.version},
        );
      });
    }

    return LayoutControl(
      control: widget.control,
      child: Container(
        color: _bgColor,
        child: Column(
          children: [
            Expanded(
              child: MessageList(
                messages: _messages,
                placeholderText: _placeholderText,
                placeholderIcon: _modeIcon,
                bgColor: _bgColor,
              ),
            ),
            ChatComposer(
              hintText: _inputHint,
              slashCommands: _slashCommands,
              onSubmit: _onSubmit,
              focusNode: _composerFocusNode,
              modeLabel: _modeLabel,
              modeIcon: _modeIcon,
              breadcrumb: _breadcrumb,
              onBreadcrumbTap: _onContextNav,
            ),
          ],
        ),
      ),
    );
  }
}
