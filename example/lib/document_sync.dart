import 'dart:async';
import 'dart:convert';

import 'package:syncable_properties/syncable_properties.dart';

import 'serialization.dart';
import 'transport.dart';

/// A factory that builds a fresh document replica for [instanceId] on this
/// node. The returned Syncable must use [nodeId] as its replica id so LWW
/// tie-breaks and echo-suppression stay correct across all documents on the
/// node.
typedef DocumentFactory = Syncable Function(String nodeId, String instanceId);

/// Multiplexes many root Syncables over a single [MessageTransport] by tagging
/// every outbound change with an `instanceId` and routing inbound changes to
/// the matching document. Unknown instance ids are lazily materialized via
/// [factory] when provided.
class DocumentSyncNode {
  final MessageTransport _transport;
  final DocumentFactory? factory;
  final Map<String, Syncable> _docs = {};
  final Map<String, StreamSubscription<SyncableChange>> _localSubs = {};
  StreamSubscription<String>? _transportSub;

  DocumentSyncNode(this._transport, {this.factory}) {
    _transportSub = _transport.onMessage.listen(_onMessage);
  }

  String get nodeId => _transport.nodeId;

  /// Documents currently registered on this node, keyed by instance id.
  Map<String, Syncable> get docs => Map.unmodifiable(_docs);

  /// Look up a registered document, or `null` if none exists yet.
  Syncable? operator [](String instanceId) => _docs[instanceId];

  /// Registers [doc] under [instanceId]. Local mutations on [doc] are sent
  /// wrapped with [instanceId]; inbound changes for that id are applied to it.
  void register(String instanceId, Syncable doc) {
    if (_docs.containsKey(instanceId)) {
      throw StateError(
        "A document with instance id '$instanceId' is already registered "
        "on node '$nodeId'.",
      );
    }
    if (doc.nodeId != nodeId) {
      throw ArgumentError(
        "Document nodeId ('${doc.nodeId}') must match the transport nodeId "
        "('$nodeId').",
      );
    }
    _docs[instanceId] = doc;
    _localSubs[instanceId] = doc.onPropertyChange.listen((change) {
      _transport.send(serializeEnvelope(instanceId, change));
    });
  }

  void _onMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final envelope = deserializeEnvelope(json);
      final change = envelope.change;
      if (change.nodeId == nodeId) return;

      final instanceId = envelope.instanceId;
      if (instanceId == null) return;

      var doc = _docs[instanceId];
      if (doc == null) {
        final create = factory;
        if (create == null) return;
        doc = create(nodeId, instanceId);
        register(instanceId, doc);
      }
      doc.applyRemoteChange(change);
    } catch (_) {
      // Skip malformed messages.
    }
  }

  void close() {
    for (final sub in _localSubs.values) {
      sub.cancel();
    }
    _localSubs.clear();
    _docs.clear();
    _transportSub?.cancel();
    _transport.close();
  }
}

/// In-memory host that gives each node a [DocumentSyncNode] over a shared hub,
/// so multiple root Syncables (e.g. Boards) can sync across nodes on one
/// connection.
class MultiBoardHost {
  final InMemoryTransportHub _hub = InMemoryTransportHub();
  final Map<String, DocumentSyncNode> _nodes = {};
  final DocumentFactory? factory;

  MultiBoardHost({this.factory});

  /// Ensures a [DocumentSyncNode] exists for [nodeId], creating one if needed.
  DocumentSyncNode node(String nodeId) {
    return _nodes.putIfAbsent(
      nodeId,
      () => DocumentSyncNode(
        _hub.createTransport(nodeId),
        factory: factory,
      ),
    );
  }

  /// Registers [board] under [boardId] on [nodeId], creating the node if needed.
  DocumentSyncNode addBoard(String nodeId, String boardId, Syncable board) {
    final syncNode = node(nodeId);
    syncNode.register(boardId, board);
    return syncNode;
  }

  void close() {
    for (final n in _nodes.values) {
      n.close();
    }
    _nodes.clear();
    _hub.close();
  }
}
