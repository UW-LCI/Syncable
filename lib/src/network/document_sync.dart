import 'dart:async';
import 'dart:convert';

import '../syncable.dart';
import '../syncable_change.dart';
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
///
/// Also handles catch-up control messages: [requestCatchUp] asks a persister
/// for document state using [catchUpMethod] ([CatchUpMethod.crdt] or
/// [CatchUpMethod.snapshot]); inbound `catchup_snapshot` frames are applied
/// accordingly.
///
/// When [autoCatchUp] is true (the default), the node requests catch-up from
/// [persisterNodeId] as soon as it is constructed (transport should already be
/// connected). Await [catchUp] to know when that initial request finishes.
class DocumentSyncNode {
  final MessageTransport _transport;
  final DocumentFactory? factory;

  /// When true, automatically calls [requestCatchUp] after construction.
  final bool autoCatchUp;

  /// Target node id for automatic and manual catch-up requests.
  final String persisterNodeId;

  /// Preferred catch-up payload for automatic and default manual requests.
  final CatchUpMethod catchUpMethod;

  final Map<String, Syncable> _docs = {};
  final Map<String, StreamSubscription<SyncableChange>> _localSubs = {};
  StreamSubscription<String>? _transportSub;
  final List<Completer<void>> _catchUpWaiters = [];
  late final Future<void> _catchUp;
  bool _suppressOutbound = false;

  DocumentSyncNode(
    this._transport, {
    this.factory,
    this.autoCatchUp = true,
    this.persisterNodeId = 'persister',
    this.catchUpMethod = CatchUpMethod.crdt,
    Duration catchUpTimeout = const Duration(seconds: 5),
  }) {
    _transportSub = _transport.onMessage.listen(_onMessage);
    if (autoCatchUp) {
      // Attach an error handler so an absent persister does not become an
      // unhandled async error when the caller does not await [catchUp].
      _catchUp = requestCatchUp(
        persisterNodeId: persisterNodeId,
        method: catchUpMethod,
        timeout: catchUpTimeout,
      ).catchError((Object _) {});
    } else {
      _catchUp = Future<void>.value();
    }
  }

  String get nodeId => _transport.nodeId;

  /// Completes when the automatic catch-up finishes (or immediately when
  /// [autoCatchUp] is false). Errors from a missing/slow persister are
  /// swallowed on this future; use [requestCatchUp] to observe failures.
  Future<void> get catchUp => _catchUp;

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
      if (_suppressOutbound) return;
      _transport.send(serializeEnvelope(instanceId, change));
    });
  }

  /// Requests catch-up from [persisterNodeId] (unicast) using [method].
  ///
  /// Completes when a `catchup_snapshot` is applied, or fails on [timeout].
  /// Defaults [persisterNodeId] / [method] to this node's configured values.
  Future<void> requestCatchUp({
    String? persisterNodeId,
    CatchUpMethod? method,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final target = persisterNodeId ?? this.persisterNodeId;
    final preferred = method ?? catchUpMethod;
    final completer = Completer<void>();
    _catchUpWaiters.add(completer);
    _transport.sendTo(
      target,
      serializeCatchupRequest(fromNodeId: nodeId, method: preferred),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _catchUpWaiters.remove(completer);
        throw TimeoutException(
          'Timed out waiting for catch-up snapshot from $target',
          timeout,
        );
      },
    );
  }

  void _onMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (isControlMessage(json)) {
        _handleControl(json);
        return;
      }

      final envelope = deserializeEnvelope(json);
      final change = envelope.change;
      if (change.nodeId == nodeId) return;

      final instanceId = envelope.instanceId;
      if (instanceId == null) return;

      final doc = _ensureDocument(instanceId);
      if (doc == null) return;
      doc.applyRemoteChange(change);
    } catch (_) {
      // Skip malformed messages.
    }
  }

  void _handleControl(Map<String, dynamic> json) {
    final parsed = parseCatchupSnapshot(json);
    if (parsed == null) return;

    _suppressOutbound = true;
    try {
      for (final entry in parsed.documents.entries) {
        final doc = _ensureDocument(entry.key);
        if (doc == null) continue;
        switch (parsed.method) {
          case CatchUpMethod.crdt:
            doc.applyCrdtJson(entry.value);
          case CatchUpMethod.snapshot:
            // Value snapshots remint CRDT identities; only DynamicSyncable
            // supports applyJson today.
            if (doc is DynamicSyncable) {
              doc.applyJson(entry.value);
            }
        }
      }
    } finally {
      _suppressOutbound = false;
      final waiters = List<Completer<void>>.from(_catchUpWaiters);
      _catchUpWaiters.clear();
      for (final c in waiters) {
        if (!c.isCompleted) c.complete();
      }
    }
  }

  Syncable? _ensureDocument(String instanceId) {
    var doc = _docs[instanceId];
    if (doc != null) return doc;
    final create = factory;
    if (create == null) return null;
    doc = create(nodeId, instanceId);
    register(instanceId, doc);
    return doc;
  }

  void close() {
    for (final sub in _localSubs.values) {
      sub.cancel();
    }
    _localSubs.clear();
    _docs.clear();
    for (final c in _catchUpWaiters) {
      if (!c.isCompleted) {
        c.completeError(StateError('DocumentSyncNode closed during catch-up'));
      }
    }
    _catchUpWaiters.clear();
    _transportSub?.cancel();
    _transport.close();
  }
}

/// In-memory host that gives each node a [DocumentSyncNode] over a shared hub,
/// so multiple root Syncables can sync across nodes on one connection.
class DocumentSyncHost {
  final InMemoryTransportHub _hub = InMemoryTransportHub();
  final Map<String, DocumentSyncNode> _nodes = {};
  final DocumentFactory? factory;

  DocumentSyncHost({this.factory});

  /// Ensures a [DocumentSyncNode] exists for [nodeId], creating one if needed.
  ///
  /// In-memory hosts have no persister, so nodes are created with
  /// `autoCatchUp: false`.
  DocumentSyncNode node(String nodeId) {
    return _nodes.putIfAbsent(
      nodeId,
      () => DocumentSyncNode(
        _hub.createTransport(nodeId),
        factory: factory,
        autoCatchUp: false,
      ),
    );
  }

  /// Registers [doc] under [instanceId] on [nodeId], creating the node if needed.
  DocumentSyncNode addDocument(
    String nodeId,
    String instanceId,
    Syncable doc,
  ) {
    final syncNode = node(nodeId);
    syncNode.register(instanceId, doc);
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
