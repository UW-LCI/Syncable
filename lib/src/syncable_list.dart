part of 'syncable.dart';

class _ListEntry<T> {
  final ElementId id;
  T value;
  bool tombstone;
  double position;

  _ListEntry(this.id, this.value, this.position)
      : tombstone = false;
}

class SyncableList<T> with IterableMixin<T> {
  final String _key;
  final String _nodeId;
  final Syncable _syncable;
  int _idCounter = 0;

  final List<_ListEntry<T>> _entries = [];
  List<T>? _cachedView;
  bool _viewDirty = true;

  static const double _initialPosition = 0.5;
  static const double _minPosition = 0.0;
  static const double _maxPosition = 1.0;

  SyncableList._internal(this._syncable, this._key, this._nodeId);

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

  void operator []=(int index, T value) {
    _ensureView();
    _updateAt(index, value);
  }

  @override
  Iterator<T> get iterator {
    _ensureView();
    return _cachedView!.iterator;
  }

  void add(T value) {
    _ensureView();
    _insertAt(_cachedView!.length, value);
  }

  void insert(int index, T value) {
    _ensureView();
    if (index < 0 || index > _cachedView!.length) {
      throw RangeError.index(index, _cachedView!);
    }
    _insertAt(index, value);
  }

  void removeAt(int index) {
    _ensureView();
    if (index < 0 || index >= _cachedView!.length) {
      throw RangeError.index(index, _cachedView!);
    }
    _removeAt(index);
  }

  List<T> toViewList() {
    _ensureView();
    return List<T>.from(_cachedView!);
  }

  void applyRemote(ListChange change) {
    switch (change) {
      case ListInsertChange(
          elementId: final id,
          value: final v,
          position: final pos
        ):
        _applyRemoteInsert(id, v as T, pos);
      case ListRemoveChange(elementId: final id):
        _applyRemoteRemove(id);
      case ListUpdateChange(elementId: final id, value: final v):
        _applyRemoteUpdate(id, v as T);
    }
  }

  List<_ListEntry<T>> _visibleSorted() {
    return _entries
        .where((e) => !e.tombstone)
        .toList()
      ..sort(_compareEntries);
  }

  int _compareEntries(_ListEntry<T> a, _ListEntry<T> b) {
    final cmp = a.position.compareTo(b.position);
    if (cmp != 0) return cmp;
    return a.id.compareTo(b.id);
  }

  void _insertAt(int index, T value) {
    final visible = _visibleSorted();

    final elementId = ElementId(_nodeId, _idCounter++);
    final position = _computeInsertPosition(index, visible);
    final entry = _ListEntry<T>(elementId, value, position);
    _entries.add(entry);
    _viewDirty = true;

    final afterId = index > 0 ? visible[index - 1].id : null;

    _syncable.emitChange(
      ListInsertChange<T>(
        propertyKey: _key,
        nodeId: _nodeId,
        lamportClock: _syncable.tick(),
        elementId: elementId,
        value: value,
        afterElementId: afterId,
        position: position,
      ),
    );
  }

  double _computeInsertPosition(int index, List<_ListEntry<T>> visible) {
    if (visible.isEmpty) {
      return _initialPosition;
    }

    final leftPos = index == 0 ? _minPosition : visible[index - 1].position;
    final rightPos =
        index >= visible.length ? _maxPosition : visible[index].position;

    return (leftPos + rightPos) / 2.0;
  }

  void _removeAt(int index) {
    final visible = _visibleSorted();
    final entry = visible[index];
    entry.tombstone = true;
    _viewDirty = true;

    _syncable.emitChange(
      ListRemoveChange<T>(
        propertyKey: _key,
        nodeId: _nodeId,
        lamportClock: _syncable.tick(),
        elementId: entry.id,
      ),
    );
  }

  void _updateAt(int index, T value) {
    final visible = _visibleSorted();
    final entry = visible[index];
    entry.value = value;
    _viewDirty = true;

    _syncable.emitChange(
      ListUpdateChange<T>(
        propertyKey: _key,
        nodeId: _nodeId,
        lamportClock: _syncable.tick(),
        elementId: entry.id,
        value: value,
      ),
    );
  }

  void _applyRemoteInsert(ElementId id, T value, double position) {
    if (_entries.any((e) => e.id == id)) return;

    _entries.add(_ListEntry<T>(id, value, position));
    _viewDirty = true;
  }

  void _applyRemoteRemove(ElementId id) {
    final entry = _entries.cast<_ListEntry<T>?>().firstWhere(
      (e) => e?.id == id,
      orElse: () => null,
    );
    if (entry == null) return;
    entry.tombstone = true;
    _viewDirty = true;
  }

  void _applyRemoteUpdate(ElementId id, T value) {
    final entry = _entries.cast<_ListEntry<T>?>().firstWhere(
      (e) => e?.id == id,
      orElse: () => null,
    );
    if (entry == null) return;
    entry.value = value;
    _viewDirty = true;
  }

  void _ensureView() {
    if (!_viewDirty) return;
    final result = <T>[];
    final sorted = _entries.toList()..sort(_compareEntries);
    for (final entry in sorted) {
      if (!entry.tombstone) {
        result.add(entry.value);
      }
    }
    _cachedView = result;
    _viewDirty = false;
  }

  Map<String, Object?> _toCrdtJson() => {
        'kind': 'list',
        'idCounter': _idCounter,
        'entries': [
          for (final e in _entries)
            {
              'id': e.id.toString(),
              'position': e.position,
              'tombstone': e.tombstone,
              'value': e.value,
            },
        ],
      };

  void _applyCrdtJson(Map<String, dynamic> json) {
    _entries.clear();
    _idCounter = json['idCounter'] as int? ?? 0;
    final rawEntries = json['entries'] as List? ?? const [];
    for (final raw in rawEntries) {
      final map = Map<String, dynamic>.from(raw as Map);
      final entry = _ListEntry<T>(
        _parseElementIdString(map['id'] as String),
        map['value'] as T,
        (map['position'] as num).toDouble(),
      );
      entry.tombstone = map['tombstone'] as bool? ?? false;
      _entries.add(entry);
    }
    _viewDirty = true;
  }
}