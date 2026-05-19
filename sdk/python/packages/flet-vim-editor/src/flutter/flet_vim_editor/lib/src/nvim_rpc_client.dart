// Minimal nvim msgpack-RPC client.
//
// Two transports:
//   * stdio   — desktop: connect to a Process spawned with `nvim --embed`.
//   * ws      — web:     connect to lab_chrome_proxy.py which has spawned
//                        `nvim --embed` and bridges its stdin/stdout to
//                        binary WebSocket frames.
//
// nvim's RPC protocol (msgpack-rpc):
//   Request:      [0, msgid, method, params]
//   Response:     [1, msgid, error, result]
//   Notification: [2, method, params]
//
// `redraw` notifications (the UI event stream produced by nvim_ui_attach)
// are demuxed into the `onRedraw` stream as flat (name, args) records;
// callers don't see the nested batching nvim emits.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart' show serialize;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

void _log(String msg) {
  // ignore: avoid_print
  print(msg);
}

class NvimNotification {
  final String method;
  final List<dynamic> params;
  NvimNotification(this.method, this.params);
}

class NvimRedrawEvent {
  final String name;
  final List<dynamic> args;
  NvimRedrawEvent(this.name, this.args);
}

class NvimRpcError implements Exception {
  final dynamic error;
  NvimRpcError(this.error);
  @override
  String toString() => 'NvimRpcError($error)';
}

class NvimRpcClient {
  // Desktop transport: nvim --embed Process; we read its stdout and
  // write its stdin. Owned by NvimManager; we just hold references.
  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  // Browser transport: WebSocket → lab_chrome_proxy.py → nvim --embed
  // stdin/stdout (the proxy spawns its own nvim per connection). The
  // proxy is a dumb byte pipe; same msgpack frames flow either way.
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;

  int _nextMsgId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final BytesBuilder _readBuf = BytesBuilder(copy: false);

  final StreamController<NvimNotification> _notifications =
      StreamController.broadcast();
  Stream<NvimNotification> get notifications => _notifications.stream;

  final StreamController<NvimRedrawEvent> _redraws =
      StreamController.broadcast();
  Stream<NvimRedrawEvent> get onRedraw => _redraws.stream;

  /// Emitted with a short reason string when the connection drops.
  final StreamController<String> _disconnects = StreamController.broadcast();
  Stream<String> get onDisconnect => _disconnects.stream;

  /// Bind to an already-spawned `nvim --embed` Process. We listen on
  /// stdout for msgpack frames and write to stdin via _send.
  Future<void> connectProcess(Process p) async {
    _process = p;
    _stdoutSub = p.stdout.listen(
      _onBytes,
      onError: (e) {
        _log('[nvim.rpc.proc] stdout err: $e');
        if (!_disconnects.isClosed) _disconnects.add('stdout err: $e');
      },
      onDone: () {
        _log('[nvim.rpc.proc] stdout closed');
        if (!_disconnects.isClosed) _disconnects.add('stdout closed');
      },
    );
    _stderrSub = p.stderr.transform(SystemEncoding().decoder).listen(
          (line) => _log('[nvim.rpc.proc.stderr] ${line.trimRight()}'),
        );
    // Surface process exit as a disconnect even if stdout never errors.
    // ignore: unawaited_futures
    p.exitCode.then((code) {
      _log('[nvim.rpc.proc] exit=$code');
      if (!_disconnects.isClosed) _disconnects.add('process exit $code');
    });
  }

  Future<void> connectWebSocket(String url) async {
    print('[wmdiag] connectWebSocket START '
        't=${DateTime.now().millisecondsSinceEpoch}');
    _ws = WebSocketChannel.connect(Uri.parse(url));
    try {
      await _ws!.ready.timeout(const Duration(seconds: 5));
      print('[wmdiag] connectWebSocket ready OK '
          't=${DateTime.now().millisecondsSinceEpoch}');
    } catch (e) {
      _log('[nvim.rpc.ws] ready timeout: $e');
      print('[wmdiag] connectWebSocket ready FAIL '
          't=${DateTime.now().millisecondsSinceEpoch} $e');
    }
    _wsSub = _ws!.stream.listen(
      (raw) {
        if (raw is List<int>) {
          _onBytes(raw);
        } else if (raw is String) {
          _onBytes(raw.codeUnits);
        }
      },
      onError: (e) {
        _log('[nvim.rpc.ws] err: $e');
        if (!_disconnects.isClosed) _disconnects.add('ws err: $e');
      },
      onDone: () {
        _log('[nvim.rpc.ws] closed');
        if (!_disconnects.isClosed) _disconnects.add('ws closed');
      },
    );
  }

  Future<void> close() async {
    try {
      _process?.kill();
    } catch (_) {}
    try {
      await _ws?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _wsSub?.cancel();
    if (!_notifications.isClosed) await _notifications.close();
    if (!_redraws.isClosed) await _redraws.close();
    if (!_disconnects.isClosed) await _disconnects.close();
  }

  void _send(Uint8List packed) {
    if (_ws != null) {
      _ws!.sink.add(packed);
    } else if (_process != null) {
      _process!.stdin.add(packed);
    }
  }

  Future<dynamic> request(String method, List<dynamic> params) {
    final id = _nextMsgId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send(serialize([0, id, method, params]));
    return completer.future;
  }

  void notify(String method, List<dynamic> params) {
    _send(serialize([2, method, params]));
  }

  void _onBytes(List<int> chunk) {
    _readBuf.add(chunk);
    while (true) {
      final bytes = _readBuf.toBytes();
      if (bytes.isEmpty) break;
      final dec = _StreamDecoder(bytes);
      dynamic frame;
      try {
        frame = dec.decode();
      } on _NeedMoreBytes {
        // Partial frame — wait for more data.
        break;
      } catch (e) {
        // Hard parse error — drop the buffer to avoid an infinite loop
        // chewing on garbage.
        _log('[nvim.rpc] parse err: $e — dropping ${bytes.length} bytes');
        _readBuf.clear();
        break;
      }
      final consumed = dec.offset;
      // Trim the consumed prefix.
      _readBuf.clear();
      if (consumed < bytes.length) {
        _readBuf.add(bytes.sublist(consumed));
      }
      _dispatch(frame);
    }
  }

  void _dispatch(dynamic frame) {
    if (frame is! List || frame.isEmpty) return;
    final type = frame[0] as int;
    if (type == 1 && frame.length >= 4) {
      final id = frame[1] as int;
      final error = frame[2];
      final result = frame[3];
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (error != null) {
        completer.completeError(NvimRpcError(error));
      } else {
        completer.complete(result);
      }
    } else if (type == 2 && frame.length >= 3) {
      final method = frame[1].toString();
      final params = (frame[2] as List?) ?? const [];
      if (method == 'redraw') {
        // params shape: [[name1, args1, args2, ...], [name2, args1, ...], ...]
        // Each inner list = one event with N batched calls. Flatten.
        for (final ev in params) {
          if (ev is! List || ev.isEmpty) continue;
          final name = ev[0].toString();
          for (var i = 1; i < ev.length; i++) {
            final args = ev[i];
            if (args is List) {
              if (!_redraws.isClosed) {
                _redraws.add(NvimRedrawEvent(name, args));
              }
            }
          }
        }
        return;
      }
      if (!_notifications.isClosed) {
        _notifications.add(NvimNotification(method, params));
      }
    } else if (type == 0 && frame.length >= 4) {
      // Request from nvim → us. Reply null so nvim doesn't hang.
      final id = frame[1] as int;
      _send(serialize([1, id, null, null]));
    }
  }

  // ── High-level convenience wrappers around RPC methods we use. ──

  /// Replace the entire buffer with `text`. If `name` is supplied, the
  /// buffer is renamed first so its bufname surfaces as the lab_save
  /// notification's argument.
  Future<void> setBufferText(String text, {String? name}) async {
    if (name != null) {
      await request('nvim_buf_set_name', [0, name]);
      await request('nvim_exec_lua', [
        r'''
local buf = ...
vim.api.nvim_buf_set_option(buf, 'buftype', 'acwrite')
vim.api.nvim_buf_set_option(buf, 'filetype', 'python')
pcall(vim.api.nvim_buf_call, buf, function()
  vim.cmd('syntax sync fromstart')
end)
''',
        [0],
      ]);
    }
    final lines = text.split('\n');
    await request('nvim_buf_set_lines', [0, 0, -1, false, lines]);
    await request('nvim_buf_set_option', [0, 'modified', false]);
    // Clear undo history so the empty→loaded transition isn't the
    // top of the stack. Without this, the user's first `u` in vim
    // wipes the buffer — a great way to lose all your code. The
    // standard `:h clear-undo` recipe: under undolevels=-1, edits
    // aren't recorded but the undo tree gets reset, so a no-op
    // edit + restore drops history. Idempotent and instant.
    try {
      await request('nvim_exec_lua', [
        r'''
local old_ul = vim.bo.undolevels
vim.bo.undolevels = -1
-- A no-op edit under undolevels=-1 clears the undo history.
-- `keepjumps` keeps the cursor where it was; we append a line and
-- immediately delete it to the black-hole register.
vim.cmd('keepjumps normal! Go')
vim.cmd('keepjumps normal! "_dd')
vim.bo.undolevels = old_ul
vim.api.nvim_buf_set_option(0, 'modified', false)
''',
        [],
      ]);
    } catch (_) {
      // Best effort — even if this fails the buffer text is still
      // correct; only the undo-clear is skipped.
    }
  }

  /// Read the entire buffer back as a single string (lines joined by \n).
  Future<String> getBufferText() async {
    final lines = await request('nvim_buf_get_lines', [0, 0, -1, false]);
    if (lines is! List) return '';
    return lines.map((l) => _coerceUtf8(l)).join('\n');
  }

  Future<bool> getModified() async {
    final v = await request('nvim_buf_get_option', [0, 'modified']);
    return v == true;
  }

  /// Cursor position (line, column), 0-based.
  Future<(int, int)> getCursor() async {
    final v = await request('nvim_win_get_cursor', [0]);
    if (v is List && v.length >= 2) {
      final row = (v[0] as num).toInt() - 1;
      final col = (v[1] as num).toInt();
      return (row < 0 ? 0 : row, col < 0 ? 0 : col);
    }
    return (0, 0);
  }

  /// Set the cursor in the current window from a 0-based (line, col).
  Future<void> setCursor(int line, int col) async {
    try {
      final lineCount = await request('nvim_buf_line_count', [0]);
      final maxLine = (lineCount as num).toInt();
      final r = line.clamp(0, maxLine - 1).toInt() + 1;
      final lines =
          await request('nvim_buf_get_lines', [0, r - 1, r, false]);
      final lineText =
          (lines is List && lines.isNotEmpty) ? lines[0].toString() : '';
      final c = col.clamp(0, lineText.length).toInt();
      await request('nvim_win_set_cursor', [
        0,
        [r, c]
      ]);
    } catch (_) {
      // Best-effort.
    }
  }

  String _coerceUtf8(dynamic v) {
    if (v is String) return v;
    if (v is Uint8List) {
      try {
        return String.fromCharCodes(v);
      } catch (_) {
        return v.toString();
      }
    }
    if (v is List<int>) return String.fromCharCodes(v);
    return v.toString();
  }
}

// ─── Stream-aware msgpack decoder ───────────────────────────────────
//
// The pub `msgpack_dart` Deserializer doesn't expose its read cursor,
// and re-packing the decoded value to compute consumed length is
// unreliable (msgpack isn't canonical — nvim and Dart serializers pick
// different encodings for the same logical value, e.g. fixint vs int8,
// str vs bin). This in-tree decoder tracks `offset` so the framing
// loop can trim exactly the bytes consumed by one frame, and throws
// `_NeedMoreBytes` on a truncated buffer so the caller can wait for
// the next chunk.
class _NeedMoreBytes implements Exception {
  const _NeedMoreBytes();
}

class _StreamDecoder {
  final Uint8List bytes;
  final ByteData _data;
  int offset = 0;

  _StreamDecoder(this.bytes)
      : _data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

  void _need(int n) {
    if (offset + n > bytes.length) throw const _NeedMoreBytes();
  }

  int _readU8() {
    _need(1);
    return _data.getUint8(offset++);
  }

  int _readI8() {
    _need(1);
    return _data.getInt8(offset++);
  }

  int _readU16() {
    _need(2);
    final v = _data.getUint16(offset);
    offset += 2;
    return v;
  }

  int _readI16() {
    _need(2);
    final v = _data.getInt16(offset);
    offset += 2;
    return v;
  }

  int _readU32() {
    _need(4);
    final v = _data.getUint32(offset);
    offset += 4;
    return v;
  }

  int _readI32() {
    _need(4);
    final v = _data.getInt32(offset);
    offset += 4;
    return v;
  }

  int _readU64() {
    _need(8);
    final v = _data.getUint64(offset);
    offset += 8;
    return v;
  }

  int _readI64() {
    _need(8);
    final v = _data.getInt64(offset);
    offset += 8;
    return v;
  }

  double _readF32() {
    _need(4);
    final v = _data.getFloat32(offset);
    offset += 4;
    return v;
  }

  double _readF64() {
    _need(8);
    final v = _data.getFloat64(offset);
    offset += 8;
    return v;
  }

  Uint8List _readBytes(int n) {
    _need(n);
    final view = Uint8List.view(bytes.buffer, bytes.offsetInBytes + offset, n);
    offset += n;
    // Copy out of the read buffer — the caller's buffer (BytesBuilder)
    // will be cleared right after this and the underlying memory may
    // be recycled.
    return Uint8List.fromList(view);
  }

  String _readString(int n) {
    final raw = _readBytes(n);
    // Most nvim payloads are ASCII; fall back to utf-8 for non-ASCII.
    var ascii = true;
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] > 127) {
        ascii = false;
        break;
      }
    }
    if (ascii) return String.fromCharCodes(raw);
    return const Utf8Codec().decode(raw);
  }

  List<dynamic> _readArray(int n) {
    final out = List<dynamic>.filled(n, null, growable: false);
    for (var i = 0; i < n; i++) {
      out[i] = decode();
    }
    return out;
  }

  Map<dynamic, dynamic> _readMap(int n) {
    final out = <dynamic, dynamic>{};
    for (var i = 0; i < n; i++) {
      final k = decode();
      final v = decode();
      out[k] = v;
    }
    return out;
  }

  // ext: type byte + N data bytes. We don't decode ext payloads here
  // (nvim sends Buffer/Window/Tabpage handles this way); the caller
  // doesn't need them since we use bufnr('%') instead of these EXT
  // values for buffer ids.
  dynamic _readExt(int n) {
    _need(1 + n);
    offset += 1 + n; // skip type + body
    return null;
  }

  dynamic decode() {
    final u = _readU8();
    if (u <= 0x7f) return u; // positive fixint
    if (u >= 0xe0) return u - 256; // negative fixint
    if ((u & 0xe0) == 0xa0) return _readString(u & 0x1f); // fixstr
    if ((u & 0xf0) == 0x90) return _readArray(u & 0x0f); // fixarray
    if ((u & 0xf0) == 0x80) return _readMap(u & 0x0f); // fixmap
    switch (u) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _readBytes(_readU8());
      case 0xc5:
        return _readBytes(_readU16());
      case 0xc6:
        return _readBytes(_readU32());
      case 0xc7:
        return _readExt(_readU8());
      case 0xc8:
        return _readExt(_readU16());
      case 0xc9:
        return _readExt(_readU32());
      case 0xca:
        return _readF32();
      case 0xcb:
        return _readF64();
      case 0xcc:
        return _readU8();
      case 0xcd:
        return _readU16();
      case 0xce:
        return _readU32();
      case 0xcf:
        return _readU64();
      case 0xd0:
        return _readI8();
      case 0xd1:
        return _readI16();
      case 0xd2:
        return _readI32();
      case 0xd3:
        return _readI64();
      case 0xd4:
        return _readExt(1);
      case 0xd5:
        return _readExt(2);
      case 0xd6:
        return _readExt(4);
      case 0xd7:
        return _readExt(8);
      case 0xd8:
        return _readExt(16);
      case 0xd9:
        return _readString(_readU8());
      case 0xda:
        return _readString(_readU16());
      case 0xdb:
        return _readString(_readU32());
      case 0xdc:
        return _readArray(_readU16());
      case 0xdd:
        return _readArray(_readU32());
      case 0xde:
        return _readMap(_readU16());
      case 0xdf:
        return _readMap(_readU32());
      default:
        throw FormatException('unknown msgpack tag 0x${u.toRadixString(16)}');
    }
  }
}
