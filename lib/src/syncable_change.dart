import 'element_id.dart';

sealed class SyncableChange {
  final String propertyKey;
  final String nodeId;
  final int lamportClock;

  /// Segments from the root Syncable down to the property's owner. Empty for a
  /// flat (non-nested) change. Each segment is a child key, optionally suffixed
  /// with `#<elementId>` when the child lives inside a [SyncableNodeList].
  final List<String> path;

  const SyncableChange({
    required this.propertyKey,
    required this.nodeId,
    required this.lamportClock,
    this.path = const [],
  });

  /// Returns a copy of this change addressed at [newPath].
  SyncableChange withPath(List<String> newPath);

  /// Returns a copy of this change with [segment] prepended to its [path].
  SyncableChange withPathPrefix(String segment) =>
      withPath([segment, ...path]);
}

class ValueSetChange<T> extends SyncableChange {
  final T value;

  const ValueSetChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required this.value,
    super.path,
  });

  @override
  ValueSetChange<T> withPath(List<String> newPath) => ValueSetChange<T>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: lamportClock,
        value: value,
        path: newPath,
      );
}

sealed class ListChange<T> extends SyncableChange {
  const ListChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    super.path,
  });
}

class ListInsertChange<T> extends ListChange<T> {
  final ElementId elementId;
  final T value;
  final ElementId? afterElementId;
  final double position;

  const ListInsertChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required this.elementId,
    required this.value,
    this.afterElementId,
    required this.position,
    super.path,
  });

  @override
  ListInsertChange<T> withPath(List<String> newPath) => ListInsertChange<T>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: lamportClock,
        elementId: elementId,
        value: value,
        afterElementId: afterElementId,
        position: position,
        path: newPath,
      );
}

class ListRemoveChange<T> extends ListChange<T> {
  final ElementId elementId;

  const ListRemoveChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required this.elementId,
    super.path,
  });

  @override
  ListRemoveChange<T> withPath(List<String> newPath) => ListRemoveChange<T>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: lamportClock,
        elementId: elementId,
        path: newPath,
      );
}

class ListUpdateChange<T> extends ListChange<T> {
  final ElementId elementId;
  final T value;

  const ListUpdateChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required this.elementId,
    required this.value,
    super.path,
  });

  @override
  ListUpdateChange<T> withPath(List<String> newPath) => ListUpdateChange<T>(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: lamportClock,
        elementId: elementId,
        value: value,
        path: newPath,
      );
}

/// Structural changes for a [SyncableNodeList] — inserting or removing a child
/// Syncable element. The element's own property mutations travel as ordinary
/// [ValueSetChange]/[ListChange] events addressed through [SyncableChange.path].
sealed class NodeListChange extends SyncableChange {
  final ElementId elementId;

  const NodeListChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required this.elementId,
    super.path,
  });
}

class NodeInsertChange extends NodeListChange {
  final ElementId? afterElementId;
  final double position;

  /// Identifies which factory builds the element on a remote replica. Null for
  /// a homogeneous [SyncableNodeList] (single factory); set for a typed
  /// (heterogeneous) list.
  final String? typeId;

  const NodeInsertChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required super.elementId,
    this.afterElementId,
    required this.position,
    this.typeId,
    super.path,
  });

  @override
  NodeInsertChange withPath(List<String> newPath) => NodeInsertChange(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: lamportClock,
        elementId: elementId,
        afterElementId: afterElementId,
        position: position,
        typeId: typeId,
        path: newPath,
      );
}

class NodeRemoveChange extends NodeListChange {
  const NodeRemoveChange({
    required super.propertyKey,
    required super.nodeId,
    required super.lamportClock,
    required super.elementId,
    super.path,
  });

  @override
  NodeRemoveChange withPath(List<String> newPath) => NodeRemoveChange(
        propertyKey: propertyKey,
        nodeId: nodeId,
        lamportClock: lamportClock,
        elementId: elementId,
        path: newPath,
      );
}
