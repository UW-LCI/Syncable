import 'dart:convert';

import 'package:syncable_properties/syncable_properties.dart';

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
