part of 'syncable.dart';

class SyncableValue<T> {
  T _value;
  int _timestamp;
  final String _key;
  final String _nodeId;
  final Syncable _syncable;

  SyncableValue._internal(
    this._syncable,
    this._key,
    this._nodeId,
    T initial,
  )   : _value = initial,
        _timestamp = 0;

  T get value => _value;

  set value(T newValue) {
    _timestamp = _syncable.tick();
    _value = newValue;
    _syncable.emitChange(
      ValueSetChange<T>(
        propertyKey: _key,
        nodeId: _nodeId,
        lamportClock: _timestamp,
        value: newValue,
      ),
    );
  }

  void applyRemote(ValueSetChange change) {
    if (change.lamportClock > _timestamp ||
        (change.lamportClock == _timestamp &&
            change.nodeId.compareTo(_nodeId) > 0)) {
      _value = change.value as T;
      _timestamp = change.lamportClock;
    }
  }
}