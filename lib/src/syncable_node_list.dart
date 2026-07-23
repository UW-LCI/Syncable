part of 'syncable.dart';

class _NodeEntry<T extends Syncable> {
  final ElementId id;
  final T node;
  double position;
  bool tombstone;

  _NodeEntry(this.id, this.node, this.position) : tombstone = false;
}

/// An ordered, CRDT-backed collection whose elements are themselves nested
/// [Syncable]s. Structural edits (insert/remove) converge like [SyncableList]
/// (RGA + fractional positions), and each element's own property mutations sync
/// through the owning tree's root.
class SyncableNodeList<T extends Syncable> with IterableMixin<T> {
  final String _key;
  final String _nodeId;
  final Syncable _syncable;

  /// Homogeneous factory (null for a typed list).
  final T Function()? _defaultFactory;

  /// typeId -> factory for a typed (heterogeneous) list (empty otherwise).
  final Map<String, T Function()> _factories;

  int _idCounter = 0;

  final List<_NodeEntry<T>> _entries = [];
  final List<SyncableChange> _pendingNested = [];
  List<T>? _cachedView;
  bool _viewDirty = true;

  static const double _initialPosition = 0.5;
  static const double _minPosition = 0.0;
  static const double _maxPosition = 1.0;

  SyncableNodeList._internal(
    this._syncable,
    this._key,
    this._nodeId,
    this._defaultFactory,
    this._factories,
  );

  bool get _isTyped => _defaultFactory == null;

  @override
  int get length {
    _ensureView();
    return _cachedView!.length;
  }

  @override
  bool get isEmpty {
    _ensureView();
    return _cachedView!.isEmpty;
  }

  @override
  bool get isNotEmpty => !isEmpty;

  @override
  T get first {
    _ensureView();
    if (_cachedView!.isEmpty) throw StateError('No element');
    return _cachedView!.first;
  }

  @override
  T get last {
    _ensureView();
    if (_cachedView!.isEmpty) throw StateError('No element');
    return _cachedView!.last;
  }

  @override
  T get single {
    _ensureView();
    if (_cachedView!.length != 1) throw StateError('Expected one element');
    return _cachedView!.single;
  }

  T operator [](int index) {
    _ensureView();
    return _cachedView![index];
  }

  @override
  Iterator<T> get iterator {
    _ensureView();
    return _cachedView!.iterator;
  }

  /// Creates a new child element at the end of the list and returns it, ready to
  /// be configured. Its subsequent mutations sync automatically. For a typed
  /// list, pass the [typeId] of the subtype to create.
  T add([String? typeId]) {
    _ensureView();
    return _insertAt(_cachedView!.length, typeId);
  }

  /// Creates a new child element at [index] and returns it. For a typed list,
  /// pass the [typeId] of the subtype to create.
  T insert(int index, [String? typeId]) {
    _ensureView();
    if (index < 0 || index > _cachedView!.length) {
      throw RangeError.index(index, _cachedView!);
    }
    return _insertAt(index, typeId);
  }

  void removeAt(int index) {
    _ensureView();
    if (index < 0 || index >= _cachedView!.length) {
      throw RangeError.index(index, _cachedView!);
    }
    final visible = _visibleSorted();
    final entry = visible[index];
    entry.tombstone = true;
    _viewDirty = true;
    entry.node.dispose();

    _syncable.emitChange(
      NodeRemoveChange(
        propertyKey: _key,
        nodeId: _nodeId,
        lamportClock: _syncable.tick(),
        elementId: entry.id,
      ),
    );
  }

  List<T> toViewList() {
    _ensureView();
    return List<T>.from(_cachedView!);
  }

  void applyRemote(SyncableChange change) {
    if (change is NodeInsertChange) {
      _applyRemoteInsert(change.elementId, change.position, change.typeId);
    } else if (change is NodeRemoveChange) {
      _applyRemoteRemove(change.elementId);
    } else {
      _routeNested(change);
    }
  }

  /// Builds a fresh element. [typeId] selects the factory for a typed list and
  /// must be null for a homogeneous list.
  T _construct(String? typeId) {
    if (!_isTyped) {
      if (typeId != null) {
        throw StateError(
          "Node list '$_key' is homogeneous; do not pass a type id.",
        );
      }
      return _defaultFactory!();
    }
    if (typeId == null) {
      throw StateError(
        "Node list '$_key' is typed; add(...) requires a type id.",
      );
    }
    final factory = _factories[typeId];
    if (factory == null) {
      throw StateError(
        "No factory registered for type id '$typeId' in node list '$_key'.",
      );
    }
    return factory();
  }

  T _insertAt(int index, String? typeId) {
    final visible = _visibleSorted();
    final elementId = ElementId(_nodeId, _idCounter++);
    final position = _computeInsertPosition(index, visible);
    final node = _construct(typeId);
    _attach(node, elementId);

    final entry = _NodeEntry<T>(elementId, node, position);
    _entries.add(entry);
    _viewDirty = true;

    final afterId = index > 0 ? visible[index - 1].id : null;

    _syncable.emitChange(
      NodeInsertChange(
        propertyKey: _key,
        nodeId: _nodeId,
        lamportClock: _syncable.tick(),
        elementId: elementId,
        afterElementId: afterId,
        position: position,
        typeId: typeId,
      ),
    );

    return node;
  }

  void _attach(T node, ElementId id) {
    assert(node._parent == null, 'child is already attached to a parent');
    node._parent = _syncable;
    node._segment = '$_key#$id';
    _syncable._absorbClock(node._lamportClock);
  }

  double _computeInsertPosition(int index, List<_NodeEntry<T>> visible) {
    if (visible.isEmpty) {
      return _initialPosition;
    }
    final leftPos = index == 0 ? _minPosition : visible[index - 1].position;
    final rightPos =
        index >= visible.length ? _maxPosition : visible[index].position;
    return (leftPos + rightPos) / 2.0;
  }

  void _applyRemoteInsert(ElementId id, double position, String? typeId) {
    if (_entries.any((e) => e.id == id)) return;
    final node = _construct(typeId);
    _attach(node, id);
    _entries.add(_NodeEntry<T>(id, node, position));
    _viewDirty = true;
    _replayPendingNested(id);
  }

  void _applyRemoteRemove(ElementId id) {
    final entry = _entryById(id);
    if (entry == null) return;
    entry.tombstone = true;
    _viewDirty = true;
    entry.node.dispose();
  }

  void _routeNested(SyncableChange change) {
    final id = _elementOf(change);
    final entry = _entryById(id);
    if (entry == null) {
      // The element's insert has not been observed yet; buffer and replay once
      // it arrives.
      _pendingNested.add(change);
      return;
    }
    entry.node._applyRemoteInternal(change.withPath(change.path.sublist(1)));
  }

  void _replayPendingNested(ElementId id) {
    final ready = _pendingNested.where((c) => _elementOf(c) == id).toList();
    for (final change in ready) {
      final entry = _entryById(id)!;
      entry.node._applyRemoteInternal(change.withPath(change.path.sublist(1)));
    }
    _pendingNested.removeWhere((c) => _elementOf(c) == id);
  }

  ElementId _elementOf(SyncableChange change) {
    final segment = change.path.first;
    final hash = segment.indexOf('#');
    return _parseElementId(segment.substring(hash + 1));
  }

  ElementId _parseElementId(String s) {
    final idx = s.lastIndexOf(':');
    return ElementId(s.substring(0, idx), int.parse(s.substring(idx + 1)));
  }

  _NodeEntry<T>? _entryById(ElementId id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  List<_NodeEntry<T>> _visibleSorted() {
    return _entries.where((e) => !e.tombstone).toList()..sort(_compareEntries);
  }

  int _compareEntries(_NodeEntry<T> a, _NodeEntry<T> b) {
    final cmp = a.position.compareTo(b.position);
    if (cmp != 0) return cmp;
    return a.id.compareTo(b.id);
  }

  void _ensureView() {
    if (!_viewDirty) return;
    final result = <T>[];
    final sorted = _entries.toList()..sort(_compareEntries);
    for (final entry in sorted) {
      if (!entry.tombstone) {
        result.add(entry.node);
      }
    }
    _cachedView = result;
    _viewDirty = false;
  }
}
