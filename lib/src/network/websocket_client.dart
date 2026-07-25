import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

/// WebSocket client transport. After [connect], the first outbound frame is
/// this transport's [nodeId] (handshake); subsequent frames are sync messages.
class WebSocketClientTransport extends MessageTransport {
  final String _url;
  WebSocketChannel? _channel;
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  WebSocketClientTransport(super.nodeId, this._url);

  Future<void> connect() async {
    _channel = WebSocketChannel.connect(Uri.parse(_url));
    await _channel!.ready;
    _channel!.stream.listen(
      (data) => _controller.add(data as String),
      onError: (error) => _controller.addError(error),
      onDone: () {
        if (!_controller.isClosed) {
          _controller.close();
        }
      },
    );
    _channel!.sink.add(nodeId);
  }

  @override
  Stream<String> get onMessage => _controller.stream;

  @override
  void send(String message) {
    _channel?.sink.add(message);
  }

  @override
  void sendTo(String targetNodeId, String message) {
    _channel?.sink.add(wrapUnicast(targetNodeId, message));
  }

  @override
  void close() {
    _channel?.sink.close();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
