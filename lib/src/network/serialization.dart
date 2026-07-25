import 'dart:convert';

import '../element_id.dart';
import '../syncable_change.dart';

class SerializationException implements Exception {
  final String message;
  SerializationException(this.message);
  @override
  String toString() => 'SerializationException: $message';
}

ElementId _parseElementId(String s) {
  final idx = s.lastIndexOf(':');
  return ElementId(s.substring(0, idx), int.parse(s.substring(idx + 1)));
}

SyncableChange deserializeChange(Map<String, dynamic> json) {
  final type = json['type'] as String;
  final propertyKey = json['propertyKey'] as String;
  final nodeId = json['nodeId'] as String;
  final clock = json['lamportClock'] as int;
  final path = (json['path'] as List?)?.cast<String>() ?? const <String>[];

  switch (type) {
    case 'value_set':
      return ValueSetChange<dynamic>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: clock,
        value: json['value'],
        path: path,
      );

    case 'list_insert':
      return ListInsertChange<dynamic>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: clock,
        elementId: _parseElementId(json['elementId'] as String),
        value: json['value'],
        afterElementId: json['afterElementId'] != null
            ? _parseElementId(json['afterElementId'] as String)
            : null,
        position: (json['position'] as num).toDouble(),
        path: path,
      );

    case 'list_remove':
      return ListRemoveChange<dynamic>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: clock,
        elementId: _parseElementId(json['elementId'] as String),
        path: path,
      );

    case 'list_update':
      return ListUpdateChange<dynamic>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: clock,
        elementId: _parseElementId(json['elementId'] as String),
        value: json['value'],
        path: path,
      );

    case 'node_insert':
      return NodeInsertChange(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: clock,
        elementId: _parseElementId(json['elementId'] as String),
        afterElementId: json['afterElementId'] != null
            ? _parseElementId(json['afterElementId'] as String)
            : null,
        position: (json['position'] as num).toDouble(),
        typeId: json['typeId'] as String?,
        path: path,
      );

    case 'node_remove':
      return NodeRemoveChange(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: clock,
        elementId: _parseElementId(json['elementId'] as String),
        path: path,
      );

    default:
      throw SerializationException('Unknown change type: $type');
  }
}

String serializeChange(SyncableChange change) {
  final map = <String, dynamic>{
    'propertyKey': change.propertyKey,
    'nodeId': change.nodeId,
    'lamportClock': change.lamportClock,
  };

  if (change.path.isNotEmpty) {
    map['path'] = change.path;
  }

  if (change is ValueSetChange) {
    map['type'] = 'value_set';
    map['value'] = change.value;
  } else if (change is ListInsertChange) {
    map['type'] = 'list_insert';
    map['elementId'] = change.elementId.toString();
    map['value'] = change.value;
    map['afterElementId'] = change.afterElementId?.toString();
    map['position'] = change.position;
  } else if (change is ListRemoveChange) {
    map['type'] = 'list_remove';
    map['elementId'] = change.elementId.toString();
  } else if (change is ListUpdateChange) {
    map['type'] = 'list_update';
    map['elementId'] = change.elementId.toString();
    map['value'] = change.value;
  } else if (change is NodeInsertChange) {
    map['type'] = 'node_insert';
    map['elementId'] = change.elementId.toString();
    map['afterElementId'] = change.afterElementId?.toString();
    map['position'] = change.position;
    map['typeId'] = change.typeId;
  } else if (change is NodeRemoveChange) {
    map['type'] = 'node_remove';
    map['elementId'] = change.elementId.toString();
  }

  return jsonEncode(map);
}

/// Serializes [change] into a JSON envelope that also carries [instanceId], so
/// a multi-document node can route the change to the correct root Syncable.
///
/// [instanceId] is orthogonal to [SyncableChange.path]: path addresses within a
/// document; instanceId selects which document.
String serializeEnvelope(String instanceId, SyncableChange change) {
  final map = jsonDecode(serializeChange(change)) as Map<String, dynamic>;
  map['instanceId'] = instanceId;
  return jsonEncode(map);
}

/// Deserializes a JSON map that may optionally include `instanceId`. Single-
/// document messages (no instanceId) still deserialize correctly.
({String? instanceId, SyncableChange change}) deserializeEnvelope(
  Map<String, dynamic> json,
) {
  return (
    instanceId: json['instanceId'] as String?,
    change: deserializeChange(json),
  );
}

/// Control-plane message types (not [SyncableChange]).
const String catchupRequestType = 'catchup_request';
const String catchupSnapshotType = 'catchup_snapshot';

/// How a client wants the persister to deliver catch-up state.
enum CatchUpMethod {
  /// Observed value tree ([Syncable.toJson] / [DynamicSyncable.applyJson]).
  /// Smaller, but remints CRDT identities on apply.
  snapshot('snapshot'),

  /// Full CRDT metadata ([Syncable.toCrdtJson] / [Syncable.applyCrdtJson]).
  /// Preserves element ids, clocks, and tombstones.
  crdt('crdt');

  const CatchUpMethod(this.wireName);
  final String wireName;

  static CatchUpMethod? tryParse(String? name) {
    if (name == null) return null;
    for (final m in values) {
      if (m.wireName == name) return m;
    }
    return null;
  }

  static CatchUpMethod parse(String? name, {CatchUpMethod fallback = crdt}) =>
      tryParse(name) ?? fallback;
}

bool isControlMessage(Map<String, dynamic> json) {
  final type = json['type'];
  return type == catchupRequestType || type == catchupSnapshotType;
}

String serializeCatchupRequest({
  required String fromNodeId,
  CatchUpMethod method = CatchUpMethod.crdt,
}) =>
    jsonEncode({
      'type': catchupRequestType,
      'fromNodeId': fromNodeId,
      'method': method.wireName,
    });

String serializeCatchupSnapshot(
  Map<String, Map<String, Object?>> documents, {
  CatchUpMethod method = CatchUpMethod.crdt,
}) =>
    jsonEncode({
      'type': catchupSnapshotType,
      'method': method.wireName,
      'documents': documents,
    });

/// Parsed catch-up response, or `null` if [json] is not a snapshot frame.
({CatchUpMethod method, Map<String, Map<String, dynamic>> documents})?
    parseCatchupSnapshot(Map<String, dynamic> json) {
  if (json['type'] != catchupSnapshotType) return null;
  final docs = json['documents'];
  if (docs is! Map) return null;
  return (
    method: CatchUpMethod.parse(json['method'] as String?),
    documents: {
      for (final e in docs.entries)
        e.key as String: Map<String, dynamic>.from(e.value as Map),
    },
  );
}

bool isCatchupRequest(Map<String, dynamic> json) =>
    json['type'] == catchupRequestType;

CatchUpMethod catchupRequestMethod(Map<String, dynamic> json) =>
    CatchUpMethod.parse(json['method'] as String?);
