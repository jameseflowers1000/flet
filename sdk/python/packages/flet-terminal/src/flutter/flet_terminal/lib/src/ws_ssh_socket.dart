import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// SSHSocket implementation over WebSocket for Flutter web clients.
///
/// websockify on the server does binary-frame bridging: each WebSocket
/// binary frame maps to raw TCP bytes.  This class wraps a WebSocketChannel
/// to satisfy dartssh2's SSHSocket interface.
class WebSocketSSHSocket implements SSHSocket {
  final WebSocketChannel _channel;
  final Completer<void> _done = Completer<void>();
  late final _TypedSink _sink;

  WebSocketSSHSocket._(this._channel) {
    _sink = _TypedSink(_channel.sink);
    _channel.stream.drain().then((_) {
      if (!_done.isCompleted) _done.complete();
    }).catchError((e) {
      if (!_done.isCompleted) _done.completeError(e);
    });
  }

  /// Connect to a websockify proxy at [wsUri].
  static Future<WebSocketSSHSocket> connect(Uri wsUri) async {
    final channel = WebSocketChannel.connect(wsUri);
    await channel.ready;
    return WebSocketSSHSocket._(channel);
  }

  @override
  Stream<Uint8List> get stream => _channel.stream.map((data) {
        if (data is Uint8List) return data;
        if (data is List<int>) return Uint8List.fromList(data);
        throw StateError('Unexpected WebSocket data type: ${data.runtimeType}');
      });

  @override
  StreamSink<List<int>> get sink => _sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    await _channel.sink.close();
    return done;
  }

  @override
  void destroy() {
    _channel.sink.close();
  }
}

/// Adapts WebSocketSink (StreamSink<dynamic>) to StreamSink<List<int>>
/// for dartssh2's SSHSocket interface.
class _TypedSink implements StreamSink<List<int>> {
  final WebSocketSink _inner;
  _TypedSink(this._inner);

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future close() => _inner.close();

  @override
  Future get done => _inner.done;
}
