import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'element_id.dart';
import 'syncable_change.dart';

part 'syncable_value.dart';
part 'syncable_list.dart';
part 'syncable_node_list.dart';
part 'dynamic_syncable.dart';

abstract class _SyncableProperty {
  void applyRemote(SyncableChange change);
}

class Syncable {
  final String nodeId;
  int _lamportClock = 0;
  final Map<String, _SyncableProperty> _properties = {};
  final List<SyncableChange> _pendingChanges = [];

  /// When this Syncable is nested inside another, [_parent] is its owner and
  /// [_segment] is the key (optionally `key#elementId`) under which it is
  /// attached. A root has a null parent and owns the clock and stream.
  Syncable? _parent;
  String? _segment;

  final StreamController<SyncableChange> _changeController =
      StreamController<SyncableChange>.broadcast(sync: true);

  Syncable(this.nodeId);

  Stream<SyncableChange> get onPropertyChange => _changeController.stream;

  int get lamportClock => _root._lamportClock;

  /// The top-most Syncable in this tree. Resolved dynamically so a node can
  /// transition from standalone to nested at runtime.
  Syncable get _root => _parent?._root ?? this;

  SyncableValue<T> syncableValue<T>(String key, T initial) {
    _ensureUnregistered(key);
    final prop = _SyncableValueAdapter<T>(
      SyncableValue<T>._internal(this, key, nodeId, initial),
    );
    _properties[key] = prop;
    _replayPending(key);
    return prop.value;
  }

  SyncableList<T> syncableList<T>(String key) {
    _ensureUnregistered(key);
    final prop = _SyncableListAdapter<T>(
      SyncableList<T>._internal(this, key, nodeId),
    );
    _properties[key] = prop;
    _replayPending(key);
    return prop.value;
  }

  /// Registers [child] as a nested Syncable under [key]. The child shares this
  /// tree's clock and its changes bubble up to the root's stream.
  T syncableChild<T extends Syncable>(String key, T child) {
    _ensureUnregistered(key);
    assert(child._parent == null, 'child is already attached to a parent');
    assert(child.nodeId == nodeId, 'child must share the replica nodeId');
    child._parent = this;
    child._segment = key;
    _root._absorbClock(child._lamportClock);
    _properties[key] = _SyncableChildAdapter(child);
    _replayPending(key);
    return child;
  }

  /// Registers a dynamic collection of child Syncables under [key]. [factory]
  /// constructs a fresh element (with default state) whenever one is created
  /// locally or observed from a remote insert. This is the homogeneous form:
  /// every element has type [T].
  SyncableNodeList<T> syncableNodeList<T extends Syncable>(
    String key,
    T Function() factory,
  ) {
    _ensureUnregistered(key);
    final prop = _SyncableNodeListAdapter<T>(
      SyncableNodeList<T>._internal(
        this,
        key,
        nodeId,
        factory,
        <String, T Function()>{},
      ),
    );
    _properties[key] = prop;
    _replayPending(key);
    return prop.value;
  }

  /// Registers a dynamic collection of child Syncables that may be of different
  /// concrete subtypes. [factories] maps a stable `typeId` to a constructor;
  /// the id travels with each insert so remote replicas rebuild the correct
  /// subtype. Add elements with `list.add('<typeId>')`.
  SyncableNodeList<T> syncableTypedNodeList<T extends Syncable>(
    String key,
    Map<String, T Function()> factories,
  ) {
    _ensureUnregistered(key);
    final prop = _SyncableNodeListAdapter<T>(
      SyncableNodeList<T>._internal(
        this,
        key,
        nodeId,
        null,
        Map<String, T Function()>.from(factories),
      ),
    );
    _properties[key] = prop;
    _replayPending(key);
    return prop.value;
  }

  void _ensureUnregistered(String key) {
    if (_properties.containsKey(key)) {
      throw StateError(
        "A syncable property with key '$key' is already registered.",
      );
    }
  }

  /// The property key a change routes through at this level: for a flat change
  /// it is [SyncableChange.propertyKey]; for a nested change it is the property
  /// portion of the first path segment (`key` from `key#elementId`).
  static String _routingKey(SyncableChange change) {
    if (change.path.isEmpty) return change.propertyKey;
    final segment = change.path.first;
    final hash = segment.indexOf('#');
    return hash == -1 ? segment : segment.substring(0, hash);
  }

  void _replayPending(String key) {
    final prop = _properties[key]!;
    final toApply =
        _pendingChanges.where((c) => _routingKey(c) == key).toList();
    for (final change in toApply) {
      prop.applyRemote(change);
      updateClock(change.lamportClock);
    }
    _pendingChanges.removeWhere((c) => _routingKey(c) == key);
  }

  int tick() {
    if (_parent == null) return ++_lamportClock;
    return _root.tick();
  }

  void updateClock(int remoteClock) {
    if (_parent == null) {
      _lamportClock = max(_lamportClock, remoteClock) + 1;
    } else {
      _root.updateClock(remoteClock);
    }
  }

  void _absorbClock(int otherClock) {
    if (_parent == null) {
      _lamportClock = max(_lamportClock, otherClock);
    } else {
      _root._absorbClock(otherClock);
    }
  }

  void emitChange(SyncableChange change) {
    if (_parent == null) {
      _changeController.add(change);
    } else {
      _parent!.emitChange(change.withPathPrefix(_segment!));
    }
  }

  void applyRemoteChange(SyncableChange change) {
    _applyRemoteInternal(change);
    updateClock(change.lamportClock);
  }

  /// Routes [change] to the correct property without touching the clock, so the
  /// clock is bumped exactly once at the tree's entry point.
  void _applyRemoteInternal(SyncableChange change) {
    final key = _routingKey(change);
    final prop = _properties[key];
    if (prop != null) {
      prop.applyRemote(change);
    } else {
      _pendingChanges.add(change);
    }
  }

  /// Exports the current observed property tree as a JSON-compatible map.
  ///
  /// Values and list elements are included as-is (must already be
  /// JSON-encodable). Nested Syncables and node-list elements become nested
  /// maps / lists of maps.
  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    for (final entry in _properties.entries) {
      final prop = entry.value;
      if (prop is _SyncableValueAdapter) {
        out[entry.key] = prop.value.value;
      } else if (prop is _SyncableListAdapter) {
        out[entry.key] = prop.value.toList();
      } else if (prop is _SyncableChildAdapter) {
        out[entry.key] = prop.child.toJson();
      } else if (prop is _SyncableNodeListAdapter) {
        out[entry.key] = [
          for (final child in prop.value) child.toJson(),
        ];
      }
    }
    return out;
  }

  /// Exports full CRDT state (clocks, element ids, positions, tombstones) for
  /// persistence and snapshot catch-up. Does not include pending buffers.
  Map<String, Object?> toCrdtJson() {
    return {
      'format': 'syncable_crdt_v1',
      'lamportClock': lamportClock,
      'properties': _toCrdtPropertiesMap(),
    };
  }

  /// Silently installs CRDT state from [toCrdtJson]. Does not emit
  /// [onPropertyChange]. Nested [DynamicSyncable] materializes missing keys.
  void applyCrdtJson(Map<String, dynamic> json) {
    final props = json['properties'];
    if (props is Map) {
      _applyCrdtPropertiesMap(Map<String, dynamic>.from(props));
    }
    if (_parent == null && json['lamportClock'] is int) {
      _lamportClock = json['lamportClock'] as int;
    }
  }

  Map<String, Object?> _toCrdtPropertiesJson() => {
        'properties': _toCrdtPropertiesMap(),
      };

  void _applyCrdtPropertiesJson(Map<String, dynamic> json) {
    final props = json['properties'];
    if (props is Map) {
      _applyCrdtPropertiesMap(Map<String, dynamic>.from(props));
    } else {
      // Allow a bare properties map for nested node payloads.
      _applyCrdtPropertiesMap(json);
    }
  }

  Map<String, Object?> _toCrdtPropertiesMap() {
    final out = <String, Object?>{};
    for (final entry in _properties.entries) {
      final prop = entry.value;
      if (prop is _SyncableValueAdapter) {
        out[entry.key] = prop.value._toCrdtJson();
      } else if (prop is _SyncableListAdapter) {
        out[entry.key] = prop.value._toCrdtJson();
      } else if (prop is _SyncableChildAdapter) {
        out[entry.key] = {
          'kind': 'child',
          'properties': prop.child._toCrdtPropertiesMap(),
        };
      } else if (prop is _SyncableNodeListAdapter) {
        out[entry.key] = prop.value._toCrdtJson();
      }
    }
    return out;
  }

  void _applyCrdtPropertiesMap(Map<String, dynamic> props) {
    for (final entry in props.entries) {
      final key = entry.key;
      final raw = entry.value;
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final kind = map['kind'] as String?;
      _ensureCrdtProperty(key, kind);
      final prop = _properties[key];
      if (prop == null) {
        throw StateError(
          "Cannot apply CRDT property '$key' (kind: $kind): not registered "
          "on $runtimeType. Access or register syncable properties before "
          "applyCrdtJson (DynamicSyncable materializes automatically).",
        );
      }
      if (prop is _SyncableValueAdapter) {
        prop.value._applyCrdtJson(map);
      } else if (prop is _SyncableListAdapter) {
        prop.value._applyCrdtJson(map);
      } else if (prop is _SyncableChildAdapter) {
        final nested = map['properties'];
        if (nested is Map) {
          prop.child._applyCrdtPropertiesMap(Map<String, dynamic>.from(nested));
        }
      } else if (prop is _SyncableNodeListAdapter) {
        prop.value._applyCrdtJson(map);
      }
    }
  }

  /// Ensures a property exists for CRDT restore. Default: no-op for typed
  /// models (properties must already be registered). [DynamicSyncable]
  /// overrides to materialize from [kind].
  void _ensureCrdtProperty(String key, String? kind) {}

  void dispose() {
    _changeController.close();
  }
}

ElementId _parseElementIdString(String s) {
  final idx = s.lastIndexOf(':');
  return ElementId(s.substring(0, idx), int.parse(s.substring(idx + 1)));
}

class _SyncableValueAdapter<T> extends _SyncableProperty {
  final SyncableValue<T> value;
  _SyncableValueAdapter(this.value);

  @override
  void applyRemote(SyncableChange change) {
    // Changes deserialized from the network lose their generic type argument
    // (arriving as `ValueSetChange<dynamic>`). Match on the raw type and
    // re-wrap with this property's concrete `T` so applying doesn't fail an
    // implicit downcast at runtime.
    if (change is ValueSetChange) {
      value.applyRemote(
        ValueSetChange<T>(
          propertyKey: change.propertyKey,
          nodeId: change.nodeId,
          lamportClock: change.lamportClock,
          value: change.value as T,
        ),
      );
    }
  }
}

class _SyncableListAdapter<T> extends _SyncableProperty {
  final SyncableList<T> value;
  _SyncableListAdapter(this.value);

  @override
  void applyRemote(SyncableChange change) {
    // See `_SyncableValueAdapter`: network-deserialized changes are typed as
    // `dynamic`, so match on the raw change kind and re-wrap with `T`.
    if (change is ListInsertChange) {
      value.applyRemote(
        ListInsertChange<T>(
          propertyKey: change.propertyKey,
          nodeId: change.nodeId,
          lamportClock: change.lamportClock,
          elementId: change.elementId,
          value: change.value as T,
          afterElementId: change.afterElementId,
          position: change.position,
        ),
      );
    } else if (change is ListRemoveChange) {
      value.applyRemote(
        ListRemoveChange<T>(
          propertyKey: change.propertyKey,
          nodeId: change.nodeId,
          lamportClock: change.lamportClock,
          elementId: change.elementId,
        ),
      );
    } else if (change is ListUpdateChange) {
      value.applyRemote(
        ListUpdateChange<T>(
          propertyKey: change.propertyKey,
          nodeId: change.nodeId,
          lamportClock: change.lamportClock,
          elementId: change.elementId,
          value: change.value as T,
        ),
      );
    }
  }
}

class _SyncableChildAdapter extends _SyncableProperty {
  final Syncable child;
  _SyncableChildAdapter(this.child);

  @override
  void applyRemote(SyncableChange change) {
    // Consume this level's path segment and route the remainder into the child.
    child._applyRemoteInternal(change.withPath(change.path.sublist(1)));
  }
}

class _SyncableNodeListAdapter<T extends Syncable> extends _SyncableProperty {
  final SyncableNodeList<T> value;
  _SyncableNodeListAdapter(this.value);

  @override
  void applyRemote(SyncableChange change) {
    value.applyRemote(change);
  }
}
