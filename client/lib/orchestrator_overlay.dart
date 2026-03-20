/// Native orchestrator overlay for the bodyless catalog screen.
///
/// Chrome extracted directly from FloatingWindowWidget (flet-window-manager),
/// with FletBackend calls removed. Same visual structure: title bar, resize
/// handles, window buttons, cyan border, drop shadow.
///
/// Chat content uses the same AgentTheme colors and markdown rendering
/// as flet-agentview.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:markdown/markdown.dart' as md;

import 'api_key.dart';
import 'claude_client.dart';
import 'native_agent.dart';

// ── Theme (AgentTheme + FloatingWindow chrome — exact values from source) ──

class _Theme {
  // Chat content (from flet-agentview models.dart AgentTheme)
  static const bgColor = Color(0xFF1A191F);
  static const inputBgColor = Color(0xFF2A2930);
  static const accentColor = Color(0xFF97C977);
  static const userBubbleColor = Color(0xFF2D4A2D);
  static const assistantBubbleColor = Color(0xFF2A2930);
  static const borderColor = Color(0xFF444444);
  static const textColor = Colors.white;
  static const mutedTextColor = Color(0xFF888888);

  // FloatingWindow chrome (from floating_window_widget.dart)
  static const titleBarColor = Color(0xFF1E1E2E);
  static const chromeColor = Color(0xFF26252D);
  static const windowBorderColor = Color(0xFF0891B3); // cyan
  static const titleBarHeight = 32.0;
  static const resizeHandleSize = 6.0;
  static const minWidth = 200.0;
  static const minHeight = 100.0;
}

// ── Chat message model ────────────────────────────────────────────────

class _ChatMessage {
  final String role;
  final String content;
  const _ChatMessage({required this.role, required this.content});
  bool get isUser => role == 'user';
}

// ── Rect for position/size (from floating_window_widget.dart) ─────────

class _Rect {
  double left, top, width, height;
  _Rect(this.left, this.top, this.width, this.height);
}

// ── Main overlay widget ───────────────────────────────────────────────

class OrchestratorOverlay extends StatefulWidget {
  final VoidCallback onClose;
  final List<Map<String, dynamic>> doclets;
  final List<String> docletPaths;
  final void Function() onDocletCreated;
  final void Function(List<String> paths) onDocletPathsChanged;
  /// Called when the agent starts/stops processing — wire to EpyxLogo busy.
  final void Function(bool busy) onBusyChanged;

  const OrchestratorOverlay({
    super.key,
    required this.onClose,
    required this.doclets,
    required this.docletPaths,
    required this.onDocletCreated,
    required this.onDocletPathsChanged,
    required this.onBusyChanged,
  });

  @override
  State<OrchestratorOverlay> createState() => _OrchestratorOverlayState();
}

class _OrchestratorOverlayState extends State<OrchestratorOverlay> {
  final List<_ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  NativeAgent? _agent;
  bool _needsApiKey = false;
  bool _showApiKeyDialog = false;
  final TextEditingController _apiKeyController = TextEditingController();

  // ── FloatingWindow state (extracted from floating_window_widget.dart) ──
  // Initial position: matches main.py orch_window (left=0, top=420, 1280×380)
  // but we compute top dynamically = vpHeight - 380.
  final _rect = ValueNotifier<_Rect>(_Rect(0, 0, 1280, 380));
  bool _maximized = false;
  double _savedLeft = 0, _savedTop = 0, _savedWidth = 0, _savedHeight = 0;
  double _vpWidth = 0, _vpHeight = 0;

  @override
  void initState() {
    super.initState();
    _initAgent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputFocusNode.requestFocus();
    });
  }

  void _initAgent() {
    final apiKey = resolveApiKey();
    if (apiKey == null) {
      setState(() => _needsApiKey = true);
      return;
    }

    final client = ClaudeClient(apiKey: apiKey);
    _agent = NativeAgent(
      llmClient: client,
      onMessage: (role, content) {
        if (mounted) {
          setState(() {
            _messages.add(_ChatMessage(role: role, content: content));
          });
          _scrollToBottom();
        }
      },
      onAction: (action, data) {
        if (action == 'doclet_created') {
          widget.onDocletCreated();
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) widget.onClose();
          });
        } else if (action == 'doclet_paths_changed') {
          final paths = (data['paths'] as List).cast<String>();
          widget.onDocletPathsChanged(paths);
        }
      },
    );
    _agent!.updateDocletContext(widget.doclets);
    _agent!.updateDocletPaths(widget.docletPaths);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _submit() {
    final text = _textController.text.trim();
    if (text.isEmpty || _agent == null || _agent!.isProcessing) return;

    setState(() {
      _messages.add(_ChatMessage(role: 'user', content: text));
    });
    _textController.clear();
    _scrollToBottom();

    // Start logo busy animation
    widget.onBusyChanged(true);

    _agent!.sendMessage(text).then((_) {
      if (mounted) {
        setState(() {});
        widget.onBusyChanged(false);
      }
    });
  }

  void _saveApiKeyAndInit() {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) return;
    saveApiKey(key);
    setState(() {
      _needsApiKey = false;
      _showApiKeyDialog = false;
    });
    _initAgent();
    _inputFocusNode.requestFocus();
  }

  @override
  void dispose() {
    _textController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _apiKeyController.dispose();
    _rect.dispose();
    super.dispose();
  }

  // ── Build: FloatingWindow chrome (from floating_window_widget.dart) ──

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _vpWidth = constraints.maxWidth;
        _vpHeight = constraints.maxHeight;

        // Set initial position: bottom of viewport, full width
        if (_rect.value.top == 0 && !_maximized) {
          _rect.value = _Rect(0, _vpHeight - 380, _vpWidth, 380);
        }

        return SizedBox.expand(
          child: ValueListenableBuilder<_Rect>(
            valueListenable: _rect,
            builder: (context, rect, _) {
              double eL, eT, eW, eH;
              if (_maximized) {
                eL = 0; eT = 0; eW = _vpWidth; eH = _vpHeight;
              } else {
                eL = rect.left; eT = rect.top;
                eW = rect.width.clamp(_Theme.minWidth, _vpWidth);
                eH = rect.height.clamp(_Theme.minHeight, _vpHeight);
              }

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: eL,
                    top: eT,
                    child: SizedBox(
                      width: eW,
                      height: eH,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(child: _buildWindowChrome()),
                          if (!_maximized) ..._buildResizeHandles(eW, eH),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// Window chrome — same structure as FloatingWindowWidget._buildWindowChrome
  Widget _buildWindowChrome() {
    return Container(
      decoration: BoxDecoration(
        color: _Theme.chromeColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _Theme.windowBorderColor, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildTitleBar(),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(7),
                bottomRight: Radius.circular(7),
              ),
              child: _buildChatBody(),
            ),
          ),
        ],
      ),
    );
  }

  /// Title bar — same structure as FloatingWindowWidget._buildTitleBar
  Widget _buildTitleBar() {
    return GestureDetector(
      onPanUpdate: _maximized
          ? null
          : (details) {
              final r = _rect.value;
              _rect.value = _Rect(
                (r.left + details.delta.dx).clamp(-r.width + 100, _vpWidth - 100),
                (r.top + details.delta.dy).clamp(0.0, _vpHeight - _Theme.titleBarHeight),
                r.width,
                r.height,
              );
            },
      onDoubleTap: _toggleMaximize,
      child: Container(
        height: _Theme.titleBarHeight,
        decoration: const BoxDecoration(
          color: _Theme.titleBarColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(7),
            topRight: Radius.circular(7),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            // Epyx neon logo — same asset as CatalogScreen EpyxLogo
            Image.asset('assets/epyx-logo-neon.png',
                height: 18, fit: BoxFit.fitHeight),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Orchestrator',
                style: TextStyle(
                  color: Color(0xFFCCCCCC),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _HoverIconButton(
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              tooltip: _maximized ? 'Restore' : 'Maximize',
              onPressed: _toggleMaximize,
              hoverColor: const Color(0x33FFFFFF),
              size: _Theme.titleBarHeight - 4,
            ),
            _HoverIconButton(
              icon: Icons.close,
              tooltip: 'Close',
              onPressed: widget.onClose,
              hoverColor: const Color(0xFFE81123),
              size: _Theme.titleBarHeight - 4,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  void _toggleMaximize() {
    if (_maximized) {
      _rect.value = _Rect(_savedLeft, _savedTop, _savedWidth, _savedHeight);
      _maximized = false;
    } else {
      final r = _rect.value;
      _savedLeft = r.left; _savedTop = r.top;
      _savedWidth = r.width; _savedHeight = r.height;
      _maximized = true;
    }
    setState(() {});
  }

  // ── Resize handles (from floating_window_widget.dart) ──────────────

  List<Widget> _buildResizeHandles(double windowWidth, double windowHeight) {
    return [
      _resizeHandle(cursor: SystemMouseCursors.resizeUp,
        left: _Theme.resizeHandleSize, top: 0,
        width: windowWidth - _Theme.resizeHandleSize * 2, height: _Theme.resizeHandleSize,
        onDrag: (dx, dy) => _resizeTop(dy)),
      _resizeHandle(cursor: SystemMouseCursors.resizeDown,
        left: _Theme.resizeHandleSize, top: windowHeight - _Theme.resizeHandleSize,
        width: windowWidth - _Theme.resizeHandleSize * 2, height: _Theme.resizeHandleSize,
        onDrag: (dx, dy) => _resizeBottom(dy)),
      _resizeHandle(cursor: SystemMouseCursors.resizeLeft,
        left: 0, top: _Theme.resizeHandleSize,
        width: _Theme.resizeHandleSize, height: windowHeight - _Theme.resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeLeft(dx)),
      _resizeHandle(cursor: SystemMouseCursors.resizeRight,
        left: windowWidth - _Theme.resizeHandleSize, top: _Theme.resizeHandleSize,
        width: _Theme.resizeHandleSize, height: windowHeight - _Theme.resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeRight(dx)),
      _resizeHandle(cursor: SystemMouseCursors.resizeUpLeft,
        left: 0, top: 0,
        width: _Theme.resizeHandleSize, height: _Theme.resizeHandleSize,
        onDrag: (dx, dy) { _resizeLeft(dx); _resizeTop(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeUpRight,
        left: windowWidth - _Theme.resizeHandleSize, top: 0,
        width: _Theme.resizeHandleSize, height: _Theme.resizeHandleSize,
        onDrag: (dx, dy) { _resizeRight(dx); _resizeTop(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeDownLeft,
        left: 0, top: windowHeight - _Theme.resizeHandleSize,
        width: _Theme.resizeHandleSize, height: _Theme.resizeHandleSize,
        onDrag: (dx, dy) { _resizeLeft(dx); _resizeBottom(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeDownRight,
        left: windowWidth - _Theme.resizeHandleSize, top: windowHeight - _Theme.resizeHandleSize,
        width: _Theme.resizeHandleSize, height: _Theme.resizeHandleSize,
        onDrag: (dx, dy) { _resizeRight(dx); _resizeBottom(dy); }),
    ];
  }

  Widget _resizeHandle({
    required SystemMouseCursor cursor,
    required double left, required double top,
    required double width, required double height,
    required void Function(double dx, double dy) onDrag,
  }) {
    return Positioned(
      left: left, top: top,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          onPanUpdate: (details) => onDrag(details.delta.dx, details.delta.dy),
          child: Container(width: width, height: height, color: Colors.transparent),
        ),
      ),
    );
  }

  void _resizeLeft(double dx) {
    final r = _rect.value;
    final nw = r.width - dx;
    final nl = r.left + dx;
    if (nw >= _Theme.minWidth && nl >= -50) {
      _rect.value = _Rect(nl, r.top, nw, r.height);
    }
  }

  void _resizeRight(double dx) {
    final r = _rect.value;
    final nw = r.width + dx;
    if (nw >= _Theme.minWidth && r.left + nw <= _vpWidth + 50) {
      _rect.value = _Rect(r.left, r.top, nw, r.height);
    }
  }

  void _resizeTop(double dy) {
    final r = _rect.value;
    final nh = r.height - dy;
    final nt = r.top + dy;
    if (nh >= _Theme.minHeight && nt >= 0) {
      _rect.value = _Rect(r.left, nt, r.width, nh);
    }
  }

  void _resizeBottom(double dy) {
    final r = _rect.value;
    final nh = r.height + dy;
    if (nh >= _Theme.minHeight && r.top + nh <= _vpHeight + 50) {
      _rect.value = _Rect(r.left, r.top, r.width, nh);
    }
  }

  // ── Chat body (same structure as orchestrator.py + agentview) ───────

  Widget _buildChatBody() {
    return Container(
      color: _Theme.bgColor,
      padding: const EdgeInsets.only(top: 2, bottom: 2, left: 2, right: 2),
      child: Column(
        children: [
          Expanded(
            child: _needsApiKey && !_showApiKeyDialog
                ? _buildApiKeyPrompt()
                : _showApiKeyDialog
                    ? _buildApiKeyInput()
                    : _messages.isEmpty
                        ? _buildPlaceholder()
                        : _buildMessageList(),
          ),
          if (!_needsApiKey || _showApiKeyDialog) _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Same neon logo as agentview placeholder (base64 icon pattern),
          // but using the asset directly since we're in the client app.
          Image.asset('assets/epyx-logo-neon.png',
              height: 48, fit: BoxFit.fitHeight,
              opacity: const AlwaysStoppedAnimation(0.4)),
          const SizedBox(height: 16),
          const Text(
            'What would you like to build?',
            style: TextStyle(color: _Theme.mutedTextColor, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'I can help you choose a template, find doclets, or create new documents.',
            style: TextStyle(
                color: _Theme.mutedTextColor.withValues(alpha: 0.6),
                fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyPrompt() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.key,
              color: _Theme.mutedTextColor.withValues(alpha: 0.5), size: 48),
          const SizedBox(height: 16),
          const Text('API Key Required',
              style: TextStyle(color: _Theme.textColor, fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          const Text('Set ANTHROPIC_API_KEY in your environment,\nor configure it here.',
              style: TextStyle(color: _Theme.mutedTextColor, fontSize: 13),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => setState(() => _showApiKeyDialog = true),
            style: TextButton.styleFrom(
              backgroundColor: _Theme.accentColor.withValues(alpha: 0.15),
              side: BorderSide(color: _Theme.accentColor.withValues(alpha: 0.4), width: 0.5),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Enter API Key',
                style: TextStyle(color: _Theme.accentColor, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyInput() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter your Anthropic API Key',
                style: TextStyle(color: _Theme.textColor, fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              style: const TextStyle(color: _Theme.textColor, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'sk-ant-...',
                hintStyle: const TextStyle(color: _Theme.mutedTextColor, fontSize: 13),
                filled: true, fillColor: _Theme.inputBgColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => _saveApiKeyAndInit(),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _showApiKeyDialog = false),
                  child: const Text('Cancel', style: TextStyle(color: _Theme.mutedTextColor)),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _saveApiKeyAndInit,
                  style: TextButton.styleFrom(backgroundColor: _Theme.accentColor.withValues(alpha: 0.15)),
                  child: const Text('Save', style: TextStyle(color: _Theme.accentColor)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (_, index) => _MessageBubble(message: _messages[index]),
    );
  }

  // ── Keyboard (same pattern as flet-agentview chat_composer.dart) ────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    // Shift+Enter → newline (let TextField handle)
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    // Enter → submit
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildComposer() {
    _inputFocusNode.onKeyEvent = _handleKeyEvent;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _Theme.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _inputFocusNode,
              maxLines: 5, minLines: 1,
              style: const TextStyle(color: _Theme.textColor, fontSize: 13),
              cursorColor: _Theme.accentColor,
              decoration: InputDecoration(
                hintText: _showApiKeyDialog ? '' : 'Ask about templates, doclets, or what to build...',
                hintStyle: const TextStyle(color: _Theme.mutedTextColor, fontSize: 13),
                filled: true, fillColor: _Theme.inputBgColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send, color: _Theme.accentColor, size: 20),
            onPressed: _submit,
            tooltip: 'Send (Enter)',
          ),
        ],
      ),
    );
  }
}

// ── HoverIconButton (from floating_window_widget.dart _HoverIconButton) ──

class _HoverIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color hoverColor;
  final double size;

  const _HoverIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.hoverColor,
    required this.size,
  });

  @override
  State<_HoverIconButton> createState() => _HoverIconButtonState();
}

class _HoverIconButtonState extends State<_HoverIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Tooltip(
          message: widget.tooltip,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hovering ? widget.hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: const Color(0xFFCCCCCC),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Message bubble (from flet-agentview message_list.dart) ────────────

class _MessageBubble extends StatelessWidget {
  final _ChatMessage message;
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
          color: isUser ? _Theme.userBubbleColor : _Theme.assistantBubbleColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: isUser ? _buildUserContent() : _buildAssistantContent(),
      ),
    );
  }

  Widget _buildUserContent() {
    return SelectableText(
      message.content,
      style: const TextStyle(color: _Theme.textColor, fontSize: 13),
    );
  }

  Widget _buildAssistantContent() {
    return SelectionArea(
      child: MarkdownBody(
        data: message.content,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        builders: {'code': _CodeElementBuilder(_darkCodeTheme)},
        styleSheet: _darkMarkdownStyleSheet(),
        shrinkWrap: true, fitContent: true, softLineBreak: true,
        onTapLink: (text, href, title) {},
      ),
    );
  }
}

// ── Markdown styling (from flet-agentview message_list.dart) ──────────

MarkdownStyleSheet _darkMarkdownStyleSheet() {
  return MarkdownStyleSheet(
    p: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
    h1: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
    h2: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
    h3: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
    h4: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
    code: const TextStyle(color: Color(0xFFE0E0E0), backgroundColor: Color(0xFF1E1E2E), fontFamily: 'monospace', fontSize: 12),
    codeblockDecoration: BoxDecoration(color: const Color(0xFF1E1E2E), borderRadius: BorderRadius.circular(8)),
    codeblockPadding: const EdgeInsets.all(12),
    blockquote: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
    blockquoteDecoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFF555555), width: 3))),
    blockquotePadding: const EdgeInsets.only(left: 12),
    listBullet: const TextStyle(color: Colors.white, fontSize: 13),
    a: const TextStyle(color: _Theme.accentColor, decoration: TextDecoration.underline),
    strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
    em: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic),
    tableHead: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
    tableBody: const TextStyle(color: Colors.white),
    tableBorder: TableBorder.all(color: const Color(0xFF444444)),
    horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF444444)))),
  );
}

// ── Code highlighting (from flet-agentview message_list.dart) ─────────

class _CodeElementBuilder extends MarkdownElementBuilder {
  final Map<String, TextStyle> codeTheme;
  _CodeElementBuilder(this.codeTheme);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    if (!element.textContent.endsWith('\n')) return null;
    var language = '';
    if (element.attributes['class'] != null) {
      final lg = element.attributes['class'] as String;
      if (lg.startsWith('language-')) language = lg.substring(9);
    }
    final source = element.textContent.substring(0, element.textContent.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          width: constraints.maxWidth == double.infinity ? 10000 : double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF1E1E2E), borderRadius: BorderRadius.circular(8)),
          child: SelectableText.rich(
            TextSpan(
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFE0E0E0)),
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
        spans.add(node.className == null
            ? TextSpan(text: node.value)
            : TextSpan(text: node.value, style: codeTheme[node.className!]));
      } else if (node.children != null) {
        spans.add(TextSpan(children: _convertNodes(node.children!), style: codeTheme[node.className!]));
      }
    }
    return spans;
  }
}

const _darkCodeTheme = <String, TextStyle>{
  'root': TextStyle(color: Color(0xFFE0E0E0), backgroundColor: Color(0xFF1E1E2E)),
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
