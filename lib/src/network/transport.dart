import 'dart:async';
import 'dart:convert';

/// JSON wrapper used by WebSocket transports for directed delivery.
/// Relays strip this before delivering [$msg] to the target's [onMessage].
const String unicastToKey = r'$to';
const String unicastMsgKey = r'$msg';

String wrapUnicast(String targetNodeId, String message) => jsonEncode({
      unicastToKey: targetNodeId,
      unicastMsgKey: message,
    });

/// If [raw] is a unicast wrapper, returns `(to, msg)`; otherwise `null`.
({String to, String msg})? parseUnicastWrapper(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final to = decoded[unicastToKey];
    final msg = decoded[unicastMsgKey];
    if (to is String && msg is String) {
      return (to: to, msg: msg);
    }
  } catch (_) {
    // Not a unicast frame.
  }
  return null;
}

abstract class MessageTransport {
  final String nodeId;
  MessageTransport(this.nodeId);
  Stream<String> get onMessage;

  /// Broadcast [message] to all other peers on the hub/relay.
  void send(String message);

  /// Deliver [message] only to [targetNodeId], if connected.
  void sendTo(String targetNodeId, String message);

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

  void unicast(String fromNodeId, String toNodeId, String message) {
    if (toNodeId == fromNodeId) return;
    _controllers[toNodeId]?.add(message);
  }

  void disconnect(String nodeId) {
    _transports.remove(nodeId);
    _controllers[nodeId]?.close();
    _controllers.remove(nodeId);
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
  void sendTo(String targetNodeId, String message) =>
      _hub.unicast(nodeId, targetNodeId, message);

  @override
  void close() => _hub.disconnect(nodeId);
}
