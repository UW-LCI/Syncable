import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

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
      onDone: () => _controller.close(),
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
  void close() {
    _channel?.sink.close();
    _controller.close();
  }
}

class WebSocketServerTransport extends MessageTransport {
  final WebSocketChannel _clientChannel;
  final void Function(String) _onReceive;

  WebSocketServerTransport(super.nodeId, this._clientChannel, this._onReceive) {
    _clientChannel.stream.listen(
      (data) => _onReceive(data as String),
      onError: (_) => close(),
      onDone: close,
    );
  }

  @override
  Stream<String> get onMessage {
    final controller = StreamController<String>.broadcast();
    return controller.stream;
  }

  @override
  void send(String message) {
    _clientChannel.sink.add(message);
  }

  @override
  void close() {
    _clientChannel.sink.close();
  }
}