class ElementId implements Comparable<ElementId> {
  final String nodeId;
  final int counter;

  const ElementId(this.nodeId, this.counter);

  @override
  int compareTo(ElementId other) {
    final cmp = nodeId.compareTo(other.nodeId);
    if (cmp != 0) return cmp;
    return counter.compareTo(other.counter);
  }

  @override
  bool operator ==(Object other) =>
      other is ElementId &&
      nodeId == other.nodeId &&
      counter == other.counter;

  @override
  int get hashCode => Object.hash(nodeId, counter);

  @override
  String toString() => '$nodeId:$counter';
}