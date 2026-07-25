part of 'syncable.dart';

/// A schema-free [Syncable] that registers properties on demand from observed
/// remote changes. Used by persistence clients that must materialize unknown
/// document shapes without domain model classes.
class DynamicSyncable extends Syncable {
  DynamicSyncable(super.nodeId);

  @override
  void _applyRemoteInternal(SyncableChange change) {
    _materializeFor(change);
    super._applyRemoteInternal(change);
  }

  void _materializeFor(SyncableChange change) {
    final key = Syncable._routingKey(change);
    if (_properties.containsKey(key)) return;

    if (change.path.isEmpty) {
      if (change is ValueSetChange) {
        syncableValue<dynamic>(key, change.value);
      } else if (change is ListChange) {
        syncableList<dynamic>(key);
      } else if (change is NodeListChange) {
        syncableNodeList<DynamicSyncable>(
          key,
          () => DynamicSyncable(nodeId),
        );
      }
      return;
    }

    final segment = change.path.first;
    if (segment.contains('#')) {
      syncableNodeList<DynamicSyncable>(
        key,
        () => DynamicSyncable(nodeId),
      );
    } else {
      syncableChild(key, DynamicSyncable(nodeId));
    }
  }

  /// Applies a JSON property tree via local mutations so changes emit on the
  /// root stream (and can be broadcast by a [DocumentSyncNode]).
  ///
  /// Shape rules match [Syncable.toJson]: scalars are values, lists of maps are
  /// node lists, other lists are primitive lists, and maps are nested children.
  void applyJson(Map<String, dynamic> json) {
    for (final entry in json.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is Map) {
        final child = _ensureChild(key);
        child.applyJson(Map<String, dynamic>.from(value));
      } else if (value is List) {
        if (value.isNotEmpty && value.every((e) => e is Map)) {
          final nodes = _ensureNodeList(key);
          for (final item in value) {
            final child = nodes.add();
            child.applyJson(Map<String, dynamic>.from(item as Map));
          }
        } else {
          final list = _ensurePrimitiveList(key);
          for (final item in value) {
            list.add(item);
          }
        }
      } else {
        final prop = _ensureValue(key);
        prop.value = value;
      }
    }
  }

  SyncableValue<dynamic> _ensureValue(String key) {
    final existing = _properties[key];
    if (existing is _SyncableValueAdapter<dynamic>) {
      return existing.value;
    }
    return syncableValue<dynamic>(key, null);
  }

  SyncableList<dynamic> _ensurePrimitiveList(String key) {
    final existing = _properties[key];
    if (existing is _SyncableListAdapter<dynamic>) {
      return existing.value;
    }
    return syncableList<dynamic>(key);
  }

  DynamicSyncable _ensureChild(String key) {
    final existing = _properties[key];
    if (existing is _SyncableChildAdapter) {
      return existing.child as DynamicSyncable;
    }
    return syncableChild(key, DynamicSyncable(nodeId));
  }

  SyncableNodeList<DynamicSyncable> _ensureNodeList(String key) {
    final existing = _properties[key];
    if (existing is _SyncableNodeListAdapter) {
      return existing.value as SyncableNodeList<DynamicSyncable>;
    }
    return syncableNodeList<DynamicSyncable>(
      key,
      () => DynamicSyncable(nodeId),
    );
  }

  @override
  void _ensureCrdtProperty(String key, String? kind) {
    if (_properties.containsKey(key)) return;
    switch (kind) {
      case 'value':
        syncableValue<dynamic>(key, null);
      case 'list':
        syncableList<dynamic>(key);
      case 'child':
        syncableChild(key, DynamicSyncable(nodeId));
      case 'nodeList':
        syncableNodeList<DynamicSyncable>(
          key,
          () => DynamicSyncable(nodeId),
        );
      default:
        break;
    }
  }
}
