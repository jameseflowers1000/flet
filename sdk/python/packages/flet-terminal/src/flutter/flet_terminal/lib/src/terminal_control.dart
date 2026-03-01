import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flet/flet.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'ws_ssh_socket.dart';

/// TerminalControl — wraps xterm + dartssh2 for SSH terminal access.
///
/// Desktop: direct TCP SSH to container sshd.
/// Web: WebSocket via websockify → TCP → sshd.
///
/// Props from Python:
///   ssh_host, ssh_port, ws_port, ssh_user, ssh_private_key,
///   font_size, theme_bg
///
/// Events to Python:
///   connected, disconnected, error
class TerminalControl extends StatefulWidget {
  static const String version = '0.1.0';

  final Control control;

  const TerminalControl({
    super.key,
    required this.control,
  });

  @override
  State<TerminalControl> createState() => _TerminalControlState();
}

class _TerminalControlState extends State<TerminalControl> {
  late final xterm.Terminal _terminal;
  SSHClient? _client;
  SSHSession? _session;
  bool _connected = false;
  bool _versionSent = false;

  // Config from Python
  String _sshHost = 'localhost';
  int _sshPort = 22;
  int _wsPort = 8551;
  String _sshUser = 'appuser';
  String? _sshPrivateKey;
  double _fontSize = 13.0;
  Color _bgColor = const Color(0xFF1A191F);

  @override
  void initState() {
    super.initState();
    _terminal = xterm.Terminal(maxLines: 10000);
    _parseConfig();
    print('[TerminalControl] initState: host=$_sshHost port=$_sshPort wsPort=$_wsPort user=$_sshUser hasKey=${_sshPrivateKey != null}');
    // Delay connect until after first layout so terminal has dimensions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      print('[TerminalControl] postFrameCallback — starting connect');
      _connect();
    });
  }

  @override
  void didUpdateWidget(covariant TerminalControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseConfig();
    // Reconnect if key connection params changed
    final oldHost = oldWidget.control.getString("ssh_host");
    final oldPort = oldWidget.control.getInt("ssh_port");
    final newHost = widget.control.getString("ssh_host");
    final newPort = widget.control.getInt("ssh_port");
    if (oldHost != newHost || oldPort != newPort) {
      _disconnect();
      _connect();
    }
  }

  void _parseConfig() {
    _sshHost = widget.control.getString("ssh_host") ?? 'localhost';
    _sshPort = widget.control.getInt("ssh_port") ?? 22;
    _wsPort = widget.control.getInt("ws_port") ?? 8551;
    _sshUser = widget.control.getString("ssh_user") ?? 'appuser';
    _sshPrivateKey = widget.control.getString("ssh_private_key");

    final fs = widget.control.getInt("font_size");
    if (fs != null && fs > 0) _fontSize = fs.toDouble();

    final bg = widget.control.getString("theme_bg");
    if (bg != null && bg.startsWith('#')) {
      String hex = bg.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      _bgColor = Color(int.parse(hex, radix: 16));
    }
  }

  Future<void> _connect() async {
    print('[TerminalControl] _connect() starting...');
    _terminal.write('Connecting to $_sshHost:$_sshPort...\r\n');

    try {
      // Choose transport: WebSocket for web, TCP for desktop
      SSHSocket socket;
      if (kIsWeb) {
        print('[TerminalControl] Web mode: connecting via WebSocket ws://$_sshHost:$_wsPort');
        final wsUri = Uri.parse('ws://$_sshHost:$_wsPort');
        socket = await WebSocketSSHSocket.connect(wsUri);
      } else {
        print('[TerminalControl] Desktop mode: connecting via TCP $_sshHost:$_sshPort');
        socket = await SSHSocket.connect(
          _sshHost,
          _sshPort,
          timeout: const Duration(seconds: 10),
        );
      }
      print('[TerminalControl] Socket connected, creating SSH client...');

      // Create SSH client with key-based auth
      _client = SSHClient(
        socket,
        username: _sshUser,
        identities: _sshPrivateKey != null
            ? SSHKeyPair.fromPem(_sshPrivateKey!)
            : [],
        onVerifyHostKey: (_, __) => true, // localhost-only, ephemeral keys
      );

      // Wait for authentication
      print('[TerminalControl] Waiting for authentication...');
      await _client!.authenticated;
      print('[TerminalControl] Authenticated! Opening shell...');

      // Open shell with PTY sized to current terminal
      print('[TerminalControl] Terminal size: ${_terminal.viewWidth}x${_terminal.viewHeight}');
      _session = await _client!.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: _terminal.viewWidth > 0 ? _terminal.viewWidth : 80,
          height: _terminal.viewHeight > 0 ? _terminal.viewHeight : 24,
        ),
      );
      print('[TerminalControl] Shell opened!');

      // Clear the "Connecting..." message
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      // Wire: SSH stdout/stderr → terminal display
      _session!.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(
        _terminal.write,
        onDone: _onSessionDone,
        onError: (e) => _onError('stdout error: $e'),
      );

      _session!.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(_terminal.write);

      // Wire: terminal user input → SSH stdin
      _terminal.onOutput = (String data) {
        _session?.write(utf8.encode(data));
      };

      // Wire: terminal resize → SSH window change
      _terminal.onResize = (int w, int h, int pw, int ph) {
        _session?.resizeTerminal(w, h, pw, ph);
      };

      _connected = true;
      _triggerEvent('connected', '');
    } catch (e, st) {
      print('[TerminalControl] Connection FAILED: $e\n$st');
      _terminal.write('\r\n\x1b[31mConnection failed: $e\x1b[0m\r\n');
      _triggerEvent('error', e.toString());
    }
  }

  void _onSessionDone() {
    _connected = false;
    _terminal.write('\r\n\x1b[33m[Session closed]\x1b[0m\r\n');
    _triggerEvent('disconnected', '');
  }

  void _onError(String msg) {
    _terminal.write('\r\n\x1b[31m[Error: $msg]\x1b[0m\r\n');
    _triggerEvent('error', msg);
  }

  void _triggerEvent(String name, String data) {
    FletBackend.of(context).triggerControlEvent(
      widget.control,
      name,
      data,
    );
  }

  void _disconnect() {
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    _connected = false;
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Send version to Python once
    if (!_versionSent) {
      _versionSent = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FletBackend.of(context).updateControl(
          widget.control.id,
          {'runtime_version': TerminalControl.version},
        );
      });
    }

    print('[TerminalControl] build() called');

    return LayoutControl(
      control: widget.control,
      child: LayoutBuilder(
        builder: (context, constraints) {
          print('[TerminalControl] constraints: $constraints');
          // Use MediaQuery for fallback if ListView gives unbounded height
          final mq = MediaQuery.of(context).size;
          final w = constraints.maxWidth.isFinite ? constraints.maxWidth : mq.width;
          final h = constraints.maxHeight.isFinite ? constraints.maxHeight : mq.height * 0.4;
          print('[TerminalControl] resolved size: ${w}x$h');
          return SizedBox(
            width: w,
            height: h,
            child: Container(
              color: _bgColor,
              child: xterm.TerminalView(
                _terminal,
                textStyle: xterm.TerminalStyle(fontSize: _fontSize),
                autofocus: true,
                autoResize: true,
                hardwareKeyboardOnly: true,
              ),
            ),
          );
        },
      ),
    );
  }
}
