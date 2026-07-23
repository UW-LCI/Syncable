import 'dart:async';

abstract class MessageTransport {
  final String nodeId;
  MessageTransport(this.nodeId);
  Stream<String> get onMessage;
  void send(String message);
  void close();
}

class InMemoryTransportHub {
  final Map<String, InMemoryTransport> _transports = {};
  final Map<String, StreamController<String>> _controllers = {};

  InMemoryTransport createTransport(String nodeId) {
    final controller = StreamController<String>.broadcast(sync: true);
    _controllers[nodeId] = controller;

    final transport = InMemoryTransport._(nodeId, this, controller);
    _transports[nodeId] = transport;
    return transport;
  }

  void broadcast(String fromNodeId, String message) {
    for (final entry in _controllers.entries) {
      if (entry.key != fromNodeId) {
        entry.value.add(message);
      }
    }
  }

  void disconnect(String nodeId) {
    _transports.remove(nodeId);
    _controllers.remove(nodeId)?.close();
  }

  void close() {
    for (final c in _controllers.values) {
      c.close();
    }
    _transports.clear();
    _controllers.clear();
  }
}

class InMemoryTransport extends MessageTransport {
  final InMemoryTransportHub _hub;
  final StreamController<String> _controller;

  InMemoryTransport._(super.nodeId, this._hub, this._controller);

  @override
  Stream<String> get onMessage => _controller.stream;

  @override
  void send(String message) => _hub.broadcast(nodeId, message);

  @override
  void close() => _hub.disconnect(nodeId);
}