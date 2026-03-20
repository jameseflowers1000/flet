/// Native orchestrator overlay for the bodyless catalog screen.
///
/// Chrome: extracted from FloatingWindowWidget (flet-window-manager),
/// FletBackend calls removed — same title bar, resize handles, window buttons.
///
/// Chat content: uses MessageList + ChatComposer from flet-agentview directly,
/// matching the exact widget tree from AgentViewControl.build().

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Use the exact same widgets the real orchestrator uses
import 'package:flet_agentview/src/chat_composer.dart';
import 'package:flet_agentview/src/message_list.dart';
import 'package:flet_agentview/src/models.dart';

import 'api_key.dart';
import 'claude_client.dart';
import 'native_agent.dart';

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
  // Chat state — same types as AgentViewControl
  final List<ChatMessage> _messages = [];
  final FocusNode _composerFocusNode = FocusNode();
  NativeAgent? _agent;
  bool _needsApiKey = false;
  bool _showApiKeyDialog = false;
  final TextEditingController _apiKeyController = TextEditingController();

  // Orch.png loaded as base64 — same as orchestrator.py get_cached_image_resource('Orch.png')
  String _orchIconBase64 = '';

  // FloatingWindow state (from floating_window_widget.dart)
  final _rect = ValueNotifier<_Rect>(_Rect(0, 0, 1280, 380));
  bool _maximized = false;
  double _savedLeft = 0, _savedTop = 0, _savedWidth = 0, _savedHeight = 0;
  double _vpWidth = 0, _vpHeight = 0;
  bool _positionInitialized = false;

  // FloatingWindow constants (from floating_window_widget.dart)
  static const _titleBarHeight = 32.0;
  static const _resizeHandleSize = 6.0;
  static const _minWidth = 200.0;
  static const _minHeight = 100.0;
  static const _borderColor = Color(0xFF0891B3);
  static const _titleBarColor = Color(0xFF1E1E2E);
  static const _chromeColor = Color(0xFF26252D);

  @override
  void initState() {
    super.initState();
    _loadOrchIcon();
    _initAgent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _composerFocusNode.requestFocus();
    });
  }

  /// Load Orch.png as base64 — same encoding the Python side uses
  /// via get_cached_image_resource() → base64.b64encode(png_bytes).
  Future<void> _loadOrchIcon() async {
    try {
      final data = await rootBundle.load('assets/Orch.png');
      setState(() {
        _orchIconBase64 = base64Encode(data.buffer.asUint8List());
      });
    } catch (_) {
      // Asset not found — placeholder icon will be used
    }
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
            _messages.add(ChatMessage(role: role, content: content));
          });
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

  void _onSubmit(String text) {
    if (text.isEmpty || _agent == null || _agent!.isProcessing) return;

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
    });

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
    _composerFocusNode.requestFocus();
  }

  @override
  void dispose() {
    _composerFocusNode.dispose();
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

        // Initial position: bottom of viewport, full width
        // (matches main.py: win_left=0, win_top=420, win_width=1280, win_height=380)
        if (!_positionInitialized) {
          _rect.value = _Rect(0, _vpHeight - 380, _vpWidth, 380);
          _positionInitialized = true;
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
                eW = rect.width.clamp(_minWidth, _vpWidth);
                eH = rect.height.clamp(_minHeight, _vpHeight);
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
        color: _chromeColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderColor, width: 1),
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
              child: _buildContent(),
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
                (r.top + details.delta.dy).clamp(0.0, _vpHeight - _titleBarHeight),
                r.width,
                r.height,
              );
            },
      onDoubleTap: _toggleMaximize,
      child: Container(
        height: _titleBarHeight,
        decoration: const BoxDecoration(
          color: _titleBarColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(7),
            topRight: Radius.circular(7),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
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
              size: _titleBarHeight - 4,
            ),
            _HoverIconButton(
              icon: Icons.close,
              tooltip: 'Close',
              onPressed: widget.onClose,
              hoverColor: const Color(0xFFE81123),
              size: _titleBarHeight - 4,
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

  // ── Content: exact same layout as AgentViewControl.build() ─────────

  Widget _buildContent() {
    if (_needsApiKey && !_showApiKeyDialog) return _buildApiKeyPrompt();
    if (_showApiKeyDialog) return _buildApiKeyInput();

    // Matches AgentViewControl.build():
    //   Container(color: bgColor)
    //     Column
    //       Expanded → MessageList(...)
    //       ChatComposer(...)
    return Container(
      color: AgentTheme.bgColor,
      child: Column(
        children: [
          Expanded(
            child: MessageList(
              messages: _messages,
              placeholderText: 'What would you like to build?',
              placeholderIcon: _orchIconBase64,
              bgColor: AgentTheme.bgColor,
            ),
          ),
          ChatComposer(
            hintText: 'Ask about templates, doclets, or what to build...',
            slashCommands: const [],
            onSubmit: _onSubmit,
            focusNode: _composerFocusNode,
            modeIcon: _orchIconBase64,
          ),
        ],
      ),
    );
  }

  Widget _buildApiKeyPrompt() {
    return Container(
      color: AgentTheme.bgColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key,
                color: AgentTheme.mutedTextColor.withValues(alpha: 0.5), size: 48),
            const SizedBox(height: 16),
            const Text('API Key Required',
                style: TextStyle(color: AgentTheme.textColor, fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            const Text('Set ANTHROPIC_API_KEY in your environment,\nor configure it here.',
                style: TextStyle(color: AgentTheme.mutedTextColor, fontSize: 13),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => setState(() => _showApiKeyDialog = true),
              style: TextButton.styleFrom(
                backgroundColor: AgentTheme.accentColor.withValues(alpha: 0.15),
                side: BorderSide(color: AgentTheme.accentColor.withValues(alpha: 0.4), width: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Enter API Key',
                  style: TextStyle(color: AgentTheme.accentColor, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApiKeyInput() {
    return Container(
      color: AgentTheme.bgColor,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your Anthropic API Key',
                  style: TextStyle(color: AgentTheme.textColor, fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 16),
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                style: const TextStyle(color: AgentTheme.textColor, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'sk-ant-...',
                  hintStyle: const TextStyle(color: AgentTheme.mutedTextColor, fontSize: 13),
                  filled: true, fillColor: AgentTheme.inputBgColor,
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
                    child: const Text('Cancel', style: TextStyle(color: AgentTheme.mutedTextColor)),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _saveApiKeyAndInit,
                    style: TextButton.styleFrom(backgroundColor: AgentTheme.accentColor.withValues(alpha: 0.15)),
                    child: const Text('Save', style: TextStyle(color: AgentTheme.accentColor)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Resize handles (from floating_window_widget.dart) ──────────────

  List<Widget> _buildResizeHandles(double windowWidth, double windowHeight) {
    return [
      _resizeHandle(cursor: SystemMouseCursors.resizeUp,
        left: _resizeHandleSize, top: 0,
        width: windowWidth - _resizeHandleSize * 2, height: _resizeHandleSize,
        onDrag: (dx, dy) => _resizeTop(dy)),
      _resizeHandle(cursor: SystemMouseCursors.resizeDown,
        left: _resizeHandleSize, top: windowHeight - _resizeHandleSize,
        width: windowWidth - _resizeHandleSize * 2, height: _resizeHandleSize,
        onDrag: (dx, dy) => _resizeBottom(dy)),
      _resizeHandle(cursor: SystemMouseCursors.resizeLeft,
        left: 0, top: _resizeHandleSize,
        width: _resizeHandleSize, height: windowHeight - _resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeLeft(dx)),
      _resizeHandle(cursor: SystemMouseCursors.resizeRight,
        left: windowWidth - _resizeHandleSize, top: _resizeHandleSize,
        width: _resizeHandleSize, height: windowHeight - _resizeHandleSize * 2,
        onDrag: (dx, dy) => _resizeRight(dx)),
      _resizeHandle(cursor: SystemMouseCursors.resizeUpLeft,
        left: 0, top: 0,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeLeft(dx); _resizeTop(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeUpRight,
        left: windowWidth - _resizeHandleSize, top: 0,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeRight(dx); _resizeTop(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeDownLeft,
        left: 0, top: windowHeight - _resizeHandleSize,
        width: _resizeHandleSize, height: _resizeHandleSize,
        onDrag: (dx, dy) { _resizeLeft(dx); _resizeBottom(dy); }),
      _resizeHandle(cursor: SystemMouseCursors.resizeDownRight,
        left: windowWidth - _resizeHandleSize, top: windowHeight - _resizeHandleSize,
        width: _resizeHandleSize, height: _resizeHandleSize,
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
    if (nw >= _minWidth && nl >= -50) {
      _rect.value = _Rect(nl, r.top, nw, r.height);
    }
  }

  void _resizeRight(double dx) {
    final r = _rect.value;
    final nw = r.width + dx;
    if (nw >= _minWidth && r.left + nw <= _vpWidth + 50) {
      _rect.value = _Rect(r.left, r.top, nw, r.height);
    }
  }

  void _resizeTop(double dy) {
    final r = _rect.value;
    final nh = r.height - dy;
    final nt = r.top + dy;
    if (nh >= _minHeight && nt >= 0) {
      _rect.value = _Rect(r.left, nt, r.width, nh);
    }
  }

  void _resizeBottom(double dy) {
    final r = _rect.value;
    final nh = r.height + dy;
    if (nh >= _minHeight && r.top + nh <= _vpHeight + 50) {
      _rect.value = _Rect(r.left, r.top, r.width, nh);
    }
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
