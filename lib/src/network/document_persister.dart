import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../syncable.dart';
import 'document_sync.dart';
import 'serialization.dart';
import 'websocket_client.dart';

/// A persisted snapshot file: `<instanceId>-<UTC stamp>.json`.
typedef SnapshotFileRef = ({String instanceId, String stamp, File file});

/// Connects to a WebSocket relay as a local client, lazily materializes every
/// discovered document root as a [DynamicSyncable], and periodically writes
/// each document's CRDT state ([Syncable.toCrdtJson]) to its own file under
/// [directory].
///
/// On [start], existing snapshots are loaded (latest per id, or latest at or
/// before [asOf]) via silent [Syncable.applyCrdtJson], then a CRDT
/// `catchup_snapshot` is broadcast so peers already on the relay hydrate
/// without a change storm. Late joiners call
/// [DocumentSyncNode.requestCatchUp] and may prefer [CatchUpMethod.crdt]
/// (full metadata) or [CatchUpMethod.snapshot] (value tree only).
///
/// Files are named `<instanceId>-<UTC timestamp>.json`. By default, older
/// copies of the same document are deleted after each successful write; set
/// [keepVersions] to retain history.
///
/// Only frames with an `instanceId` are persisted (same as [DocumentSyncNode]).
/// Legacy value-only snapshot files (no `format` field) are still loaded via
/// [DynamicSyncable.applyJson] and upgraded on the next flush.
class DocumentPersister {
  final String wsUrl;
  final Directory directory;
  final Duration interval;
  final String nodeId;
  final bool keepVersions;

  /// When set, load the latest snapshot at or before this UTC time per document.
  final DateTime? asOf;

  DocumentSyncNode? _node;
  WebSocketClientTransport? _transport;
  StreamSubscription<String>? _controlSub;
  Timer? _timer;
  int _documentsLoaded = 0;

  DocumentPersister({
    required this.wsUrl,
    required this.directory,
    this.interval = const Duration(seconds: 60),
    this.nodeId = 'persister',
    this.keepVersions = false,
    this.asOf,
  });

  /// Documents currently held by the underlying sync node.
  Map<String, Syncable> get docs => _node?.docs ?? const {};

  /// Number of documents reconstituted from disk during the last [start].
  int get documentsLoaded => _documentsLoaded;

  Future<void> start() async {
    if (_node != null) {
      throw StateError('DocumentPersister has already been started.');
    }
    await directory.create(recursive: true);

    final transport = WebSocketClientTransport(nodeId, wsUrl);
    await transport.connect();
    _transport = transport;

    // Intercept control messages before DocumentSyncNode (catch-up requests).
    _controlSub = transport.onMessage.listen(_onTransportMessage);

    final node = DocumentSyncNode(
      transport,
      factory: (id, _) => DynamicSyncable(id),
      // The persister *serves* catch-up; it must not request from itself.
      autoCatchUp: false,
    );
    _node = node;

    final loaded = _loadFromDisk(node);
    _documentsLoaded = loaded.total;
    if (loaded.crdtCount > 0) {
      // Silent CRDT restore does not emit changes; notify already-connected peers.
      _broadcastSnapshot();
    }
    _timer = Timer.periodic(interval, (_) => flush());
  }

  void _onTransportMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (!isCatchupRequest(json)) return;
      final from = json['fromNodeId'] as String?;
      if (from == null || from.isEmpty) return;
      _sendSnapshotTo(from, catchupRequestMethod(json));
    } catch (_) {
      // Ignore malformed frames.
    }
  }

  Map<String, Map<String, Object?>> _documentsForMethod(CatchUpMethod method) {
    final node = _node;
    if (node == null) return {};
    return switch (method) {
      CatchUpMethod.crdt => {
          for (final e in node.docs.entries) e.key: e.value.toCrdtJson(),
        },
      CatchUpMethod.snapshot => {
          for (final e in node.docs.entries) e.key: e.value.toJson(),
        },
    };
  }

  void _broadcastSnapshot() {
    final transport = _transport;
    if (transport == null) return;
    // Load notification uses CRDT so already-connected peers keep identities.
    final docs = _documentsForMethod(CatchUpMethod.crdt);
    if (docs.isEmpty) return;
    transport.send(
      serializeCatchupSnapshot(docs, method: CatchUpMethod.crdt),
    );
  }

  void _sendSnapshotTo(String targetNodeId, CatchUpMethod method) {
    final transport = _transport;
    if (transport == null) return;
    transport.sendTo(
      targetNodeId,
      serializeCatchupSnapshot(
        _documentsForMethod(method),
        method: method,
      ),
    );
  }

  /// Selects one snapshot file per instance id (latest, or latest ≤ [asOf]).
  Map<String, File> selectFilesToLoad({DateTime? asOf}) {
    final cutoff = asOf ?? this.asOf;
    final asOfStamp = cutoff != null ? formatUtcStamp(cutoff.toUtc()) : null;
    final best = <String, SnapshotFileRef>{};

    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final parsed = parseSnapshotFileName(name);
      if (parsed == null) continue;
      if (asOfStamp != null && parsed.stamp.compareTo(asOfStamp) > 0) {
        continue;
      }
      final prev = best[parsed.instanceId];
      if (prev == null || parsed.stamp.compareTo(prev.stamp) > 0) {
        best[parsed.instanceId] = (
          instanceId: parsed.instanceId,
          stamp: parsed.stamp,
          file: entity,
        );
      }
    }

    return {for (final e in best.entries) e.key: e.value.file};
  }

  ({int total, int crdtCount}) _loadFromDisk(DocumentSyncNode node) {
    final files = selectFilesToLoad(asOf: asOf);
    var total = 0;
    var crdtCount = 0;
    for (final entry in files.entries) {
      final raw = jsonDecode(entry.value.readAsStringSync());
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final doc = DynamicSyncable(nodeId);
      node.register(entry.key, doc);
      if (map['format'] == 'syncable_crdt_v1') {
        doc.applyCrdtJson(map);
        crdtCount++;
      } else {
        // Legacy value-only snapshot (emits changes for already-connected peers).
        doc.applyJson(map);
      }
      total++;
    }
    return (total: total, crdtCount: crdtCount);
  }

  /// Writes each known document to
  /// `$directory/<sanitizedInstanceId>-<UTC stamp>.json`.
  void flush() {
    final node = _node;
    if (node == null) return;

    final stamp = formatUtcStamp(DateTime.now().toUtc());
    for (final entry in node.docs.entries) {
      final sanitized = sanitizeFileName(entry.key);
      final fileName = '$sanitized-$stamp.json';
      final target = File('${directory.path}${Platform.pathSeparator}$fileName');
      final tmp = File('${target.path}.tmp');
      final json =
          const JsonEncoder.withIndent('  ').convert(entry.value.toCrdtJson());
      tmp.writeAsStringSync(json);
      tmp.renameSync(target.path);

      if (!keepVersions) {
        _deleteOlderCopies(sanitized, keepFileName: fileName);
      }
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _controlSub?.cancel();
    _controlSub = null;
    _node?.close();
    _node = null;
    _transport = null;
  }

  void _deleteOlderCopies(String sanitizedId, {required String keepFileName}) {
    final pattern = RegExp(
      '^${RegExp.escape(sanitizedId)}-\\d{8}T\\d{6}Z\\.json\$',
    );
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == keepFileName) continue;
      if (pattern.hasMatch(name)) {
        entity.deleteSync();
      }
    }
  }

  /// Parses `<instanceId>-<yyyyMMddTHHmmssZ>.json`.
  static ({String instanceId, String stamp})? parseSnapshotFileName(
    String fileName,
  ) {
    final match = RegExp(r'^(.*)-(\d{8}T\d{6}Z)\.json$').firstMatch(fileName);
    if (match == null) return null;
    return (instanceId: match.group(1)!, stamp: match.group(2)!);
  }

  /// Formats a UTC [DateTime] as `yyyyMMddTHHmmssZ`.
  static String formatUtcStamp(DateTime utc) {
    final u = utc.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}'
        '${two(u.month)}'
        '${two(u.day)}'
        'T'
        '${two(u.hour)}'
        '${two(u.minute)}'
        '${two(u.second)}'
        'Z';
  }

  /// Parses a `yyyyMMddTHHmmssZ` stamp into a UTC [DateTime], or `null`.
  static DateTime? parseUtcStamp(String stamp) {
    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
        .firstMatch(stamp);
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  static String sanitizeFileName(String instanceId) {
    return instanceId.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
  }
}
