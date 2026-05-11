// Dart-side LSP client for the lab.
//
// Talks to the Epyx pygls server (`epyx.lsp.server`) launched as a
// subprocess on stdio. Implements the slice of LSP we need for the
// native editor:
//   - initialize / initialized handshake
//   - textDocument/didOpen, didChange (Full sync)
//   - textDocument/completion (request → response)
//   - textDocument/publishDiagnostics (notification → stream)
//
// Hover + signature help come next; this client exposes hooks for both.
//
// Transport: Content-Length-framed JSON-RPC over the subprocess's
// stdin/stdout, exactly like neovim talks to it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

class LspCompletionItem {
  final String label;
  final String? detail;
  final String? documentation;
  final String? insertText;
  final int? kind; // LSP CompletionItemKind enum

  LspCompletionItem({
    required this.label,
    this.detail,
    this.documentation,
    this.insertText,
    this.kind,
  });

  factory LspCompletionItem.fromJson(Map<String, dynamic> j) {
    final doc = j['documentation'];
    String? docStr;
    if (doc is String) {
      docStr = doc;
    } else if (doc is Map && doc['value'] is String) {
      docStr = doc['value'] as String;
    }
    return LspCompletionItem(
      label: j['label'] as String,
      detail: j['detail'] as String?,
      documentation: docStr,
      insertText: j['insertText'] as String?,
      kind: (j['kind'] as num?)?.toInt(),
    );
  }
}

class LspDiagnostic {
  final int line;
  final int startCol;
  final int endLine;
  final int endCol;
  final String message;
  final int severity; // 1=Error 2=Warning 3=Info 4=Hint
  LspDiagnostic({
    required this.line,
    required this.startCol,
    required this.endLine,
    required this.endCol,
    required this.message,
    required this.severity,
  });

  factory LspDiagnostic.fromJson(Map<String, dynamic> j) {
    final r = j['range'] as Map<String, dynamic>;
    final s = r['start'] as Map<String, dynamic>;
    final e = r['end'] as Map<String, dynamic>;
    return LspDiagnostic(
      line: (s['line'] as num).toInt(),
      startCol: (s['character'] as num).toInt(),
      endLine: (e['line'] as num).toInt(),
      endCol: (e['character'] as num).toInt(),
      message: (j['message'] as String?) ?? '',
      severity: (j['severity'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Reads Content-Length-framed JSON-RPC messages off a byte stream,
/// emitting parsed-JSON Maps.
class _JsonRpcDecoder extends StreamTransformerBase<List<int>, dynamic> {
  @override
  Stream<dynamic> bind(Stream<List<int>> stream) async* {
    final buf = BytesBuilder(copy: false);
    int? expected;
    await for (final chunk in stream) {
      buf.add(chunk);
      while (true) {
        var bytes = buf.toBytes();
        if (expected == null) {
          // Look for header end (\r\n\r\n).
          final idx = _indexOfDoubleCrlf(bytes);
          if (idx < 0) break;
          final header = utf8.decode(bytes.sublist(0, idx));
          final m = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
              .firstMatch(header);
          if (m == null) {
            // Unknown header — drop everything and re-sync.
            buf.clear();
            break;
          }
          expected = int.parse(m.group(1)!);
          // Drop header + \r\n\r\n from buffer.
          final rest = bytes.sublist(idx + 4);
          buf.clear();
          buf.add(rest);
        } else {
          bytes = buf.toBytes();
          if (bytes.length < expected) break;
          final body = utf8.decode(bytes.sublist(0, expected));
          final tail = bytes.sublist(expected);
          buf.clear();
          buf.add(tail);
          expected = null;
          try {
            yield jsonDecode(body);
          } catch (e) {
            debugPrint('[lsp] decode error: $e body=${body.substring(0, 200)}');
          }
        }
      }
    }
  }

  int _indexOfDoubleCrlf(Uint8List bytes) {
    for (int i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 0x0d &&
          bytes[i + 1] == 0x0a &&
          bytes[i + 2] == 0x0d &&
          bytes[i + 3] == 0x0a) {
        return i;
      }
    }
    return -1;
  }
}

class LspClient {
  // Stdio transport (desktop): we spawn pygls as a subprocess.
  final String pythonPath;
  final String repoSrcPath;

  // WebSocket transport (web/Chrome dev): we connect to an external
  // pygls running with `--ws PORT`. Set when constructed via
  // `LspClient.webSocket(...)`. When non-null, no subprocess is spawned;
  // start() just opens the WS and pumps JSON-RPC frames over it.
  final String? wsUrl;

  void Function(List<LspDiagnostic>, String uri)? onDiagnostics;

  Process? _proc;
  WebSocketChannel? _ws;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final Set<String> _openDocs = {};
  bool _initialized = false;
  StreamSubscription? _sub;
  StreamSubscription? _stderrSub;
  // Health tracking — surfaces "LSP DOWN" in the chrome status bar.
  // We rely on subprocess-exit + stdout-onDone (stdio path) and
  // ws-stream-onDone/onError (web path) to flip `_connectionAlive`.
  // No activity window — idle LSP (no recent typing) must NOT show
  // as down.
  bool _connectionAlive = false;
  String _lastError = '';

  /// True when the transport is up AND we've completed the LSP
  /// `initialize` handshake. We deliberately do NOT require recent
  /// activity here — LSP is idle whenever the user isn't typing, and
  /// an idle-but-alive server should NOT trip the red banner. Real
  /// death is detected via subprocess-exit / socket-close paths
  /// which flip `_connectionAlive = false`.
  bool get isHealthy => _initialized && _connectionAlive;

  /// Last error message reported by the transport (closed socket,
  /// failed handshake, decode failure, …). Empty when never errored.
  String get lastError => _lastError;

  LspClient({
    required this.pythonPath,
    required this.repoSrcPath,
    this.onDiagnostics,
  }) : wsUrl = null;

  /// Connect to an externally-running pygls in WebSocket mode (the
  /// browser dev path). Skips subprocess spawning entirely; the caller
  /// is responsible for ensuring `python -m epyx.lsp.server --ws N`
  /// (or the lab_dev_servers.sh script) is already up.
  LspClient.webSocket({
    required String url,
    this.onDiagnostics,
  })  : wsUrl = url,
        pythonPath = '',
        repoSrcPath = '';

  Future<void> start() async {
    if (wsUrl != null) {
      debugPrint('[lsp] connecting via WebSocket: $wsUrl');
      _ws = WebSocketChannel.connect(Uri.parse(wsUrl!));
      try {
        await _ws!.ready.timeout(const Duration(seconds: 5));
        _connectionAlive = true;
      } catch (e) {
        _lastError = 'WS ready timeout: $e';
        debugPrint('[lsp] $_lastError');
      }
      _sub = _ws!.stream.listen(
        (raw) {
          try {
            final str = raw is String ? raw : utf8.decode(raw as List<int>);
            final obj = jsonDecode(str);
            _dispatch(obj);
          } catch (e) {
            _lastError = 'WS decode: $e';
            debugPrint('[lsp.ws] decode err: $e on ${raw.runtimeType}');
          }
        },
        onError: (e) {
          _lastError = 'WS stream: $e';
          _connectionAlive = false;
          debugPrint('[lsp.ws] stream err: $e');
        },
        onDone: () {
          _connectionAlive = false;
          _lastError = 'WS closed by server';
          debugPrint('[lsp.ws] connection closed');
        },
      );
    } else {
      debugPrint('[lsp] spawning $pythonPath -m epyx.lsp.server');
      _proc = await Process.start(
        pythonPath,
        ['-c', 'from epyx.lsp.server import server; server.start_io()'],
        environment: {
          'PYTHONPATH': repoSrcPath,
          'EPYX_LSP_DEBUG': '1',
        },
        includeParentEnvironment: true,
      );
      _connectionAlive = true;
      _sub = _proc!.stdout
          .transform(_JsonRpcDecoder())
          .listen(
        (raw) {
          _dispatch(raw);
        },
        onError: (e) {
          _lastError = 'stdout: $e';
          _connectionAlive = false;
          debugPrint('[lsp] stdout err: $e');
        },
        onDone: () {
          _connectionAlive = false;
          _lastError = 'stdout closed (subprocess died)';
          debugPrint('[lsp] subprocess stdout closed');
        },
      );
      _stderrSub = _proc!.stderr.transform(utf8.decoder).listen((line) {
        debugPrint('[lsp.stderr] ${line.trimRight()}');
      });
      // Watch for subprocess exit explicitly — `onDone` on stdout
      // catches most cases but exit-code surfacing is more useful.
      _proc!.exitCode.then((code) {
        _connectionAlive = false;
        if (_lastError.isEmpty) {
          _lastError = 'subprocess exited with code $code';
        }
        debugPrint('[lsp] subprocess exited: $code');
      });
    }
    final initResult = await _request('initialize', {
      // On web, dart:io's `pid` getter throws (ProcessUtils._pid unsupported).
      // The LSP spec accepts null here — it's an informational hint for the
      // server about the parent process, not load-bearing.
      'processId': wsUrl != null ? null : pid,
      'rootUri': null,
      'capabilities': {
        'textDocument': {
          'synchronization': {'didSave': false, 'willSave': false},
          'completion': {
            'completionItem': {
              'snippetSupport': false,
              'documentationFormat': ['plaintext', 'markdown'],
            },
          },
          'hover': {'contentFormat': ['markdown', 'plaintext']},
          'publishDiagnostics': {'relatedInformation': false},
        },
      },
    });
    debugPrint('[lsp] initialize OK: ${initResult is Map ? initResult.keys.toList() : initResult}');
    _notify('initialized', {});
    _initialized = true;
  }

  Future<void> stop() async {
    try {
      if (_initialized) {
        await _request('shutdown', null).timeout(const Duration(seconds: 2));
        _notify('exit', null);
      }
    } catch (_) {}
    await _sub?.cancel();
    await _stderrSub?.cancel();
    _proc?.kill();
    _proc = null;
    try {
      await _ws?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _ws = null;
  }

  void didOpen(String uri, String text, {String languageId = 'python'}) {
    if (!_initialized) return;
    _openDocs.add(uri);
    _notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': languageId,
        'version': 1,
        'text': text,
      },
    });
  }

  void didChange(String uri, String text, {required int version}) {
    if (!_initialized) return;
    if (!_openDocs.contains(uri)) {
      didOpen(uri, text);
      return;
    }
    _notify('textDocument/didChange', {
      'textDocument': {'uri': uri, 'version': version},
      'contentChanges': [
        {'text': text}, // FULL sync
      ],
    });
  }

  Future<List<LspCompletionItem>> completion(
      String uri, int line, int character) async {
    if (!_initialized) return const [];
    final result = await _request('textDocument/completion', {
      'textDocument': {'uri': uri},
      'position': {'line': line, 'character': character},
    });
    if (result == null) return const [];
    final items = (result is Map && result['items'] is List)
        ? result['items'] as List
        : (result is List ? result : const []);
    return items
        .whereType<Map<String, dynamic>>()
        .map(LspCompletionItem.fromJson)
        .toList();
  }

  /// Hover docs for the symbol at (line, character) — markdown when
  /// available, plain string otherwise. Returns the empty string for
  /// "no docs at this position" rather than null so callers can
  /// just-render-it without ceremony.
  Future<String> hover(String uri, int line, int character) async {
    if (!_initialized) return '';
    try {
      final result = await _request('textDocument/hover', {
        'textDocument': {'uri': uri},
        'position': {'line': line, 'character': character},
      });
      if (result is! Map) return '';
      final contents = result['contents'];
      if (contents is String) return contents;
      if (contents is Map) {
        final v = contents['value'];
        if (v is String) return v;
      }
      if (contents is List) {
        // Multiple hover items — concatenate string forms with \n.
        final parts = <String>[];
        for (final item in contents) {
          if (item is String) {
            parts.add(item);
          } else if (item is Map && item['value'] is String) {
            parts.add(item['value'] as String);
          }
        }
        return parts.join('\n\n');
      }
    } catch (_) {}
    return '';
  }

  // ── Internal plumbing ────────────────────────────────────────────────

  Future<dynamic> _request(String method, Object? params) {
    final id = _nextId++;
    final msg = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send(msg);
    return completer.future;
  }

  void _notify(String method, Object? params) {
    final msg = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
    _send(msg);
  }
  // ignore_for_file: use_null_aware_elements

  void _send(Map<String, dynamic> msg) {
    final body = jsonEncode(msg);
    if (_ws != null) {
      // pygls WebSocket transport: one JSON message per WS frame, no
      // Content-Length header. Send as text — receivers on either side
      // accept text or binary, but text avoids any utf8 round-tripping.
      _ws!.sink.add(body);
      return;
    }
    final bytes = utf8.encode(body);
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';
    _proc?.stdin.add(utf8.encode(header));
    _proc?.stdin.add(bytes);
  }

  void _dispatch(dynamic raw) {
    if (raw is! Map) return;
    final msg = raw.cast<String, dynamic>();
    if (msg.containsKey('id') &&
        (msg.containsKey('result') || msg.containsKey('error'))) {
      final id = (msg['id'] as num).toInt();
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (msg.containsKey('error')) {
        completer.completeError(msg['error']);
      } else {
        completer.complete(msg['result']);
      }
      return;
    }
    final method = msg['method'] as String?;
    if (method == null) return;
    if (method == 'textDocument/publishDiagnostics') {
      final params = msg['params'] as Map<String, dynamic>;
      final uri = params['uri'] as String;
      final diags = (params['diagnostics'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LspDiagnostic.fromJson)
          .toList();
      debugPrint('[lsp.recv] publishDiagnostics uri=$uri count=${diags.length} '
          'handler=${onDiagnostics != null}');
      onDiagnostics?.call(diags, uri);
    } else if (method == 'window/logMessage' || method == 'window/showMessage') {
      final params = msg['params'] as Map<String, dynamic>;
      debugPrint('[lsp.$method] ${params['message']}');
    }
  }
}
