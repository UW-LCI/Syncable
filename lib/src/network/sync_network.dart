import 'dart:async';
import 'dart:convert';

import '../syncable.dart';
import '../syncable_change.dart';
import 'serialization.dart';
import 'transport.dart';

class SyncNetwork {
  final MessageTransport _transport;
  final Syncable _model;
  StreamSubscription<String>? _subscription;

  SyncNetwork(this._transport, this._model) {
    _subscription = _transport.onMessage.listen(_onMessage);
    _model.onPropertyChange.listen(_onLocalChange);
  }

  String get nodeId => _transport.nodeId;

  void _onLocalChange(SyncableChange change) {
    final json = serializeChange(change);
    _transport.send(json);
  }

  void _onMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final change = deserializeChange(json);
      if (change.nodeId != nodeId) {
        _model.applyRemoteChange(change);
      }
    } catch (_) {
      // Skip malformed messages
    }
  }

  void close() {
    _subscription?.cancel();
    _transport.close();
  }
}

class SyncNodeHost {
  final InMemoryTransportHub _hub = InMemoryTransportHub();
  final Map<String, SyncNetwork> _networks = {};

  SyncNetwork addNode(String nodeId, Syncable model) {
    final transport = _hub.createTransport(nodeId);
    final network = SyncNetwork(transport, model);
    _networks[nodeId] = network;
    return network;
  }

  void removeNode(String nodeId) {
    _networks[nodeId]?.close();
    _networks.remove(nodeId);
  }

  void close() {
    for (final network in _networks.values) {
      network.close();
    }
    _hub.close();
  }
}
