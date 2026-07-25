import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncable/syncable.dart';

class _Child extends Syncable {
  _Child(super.nodeId);

  late final SyncableValue<String> label = syncableValue('label', '');
}

class _Source extends Syncable {
  _Source(super.nodeId);

  late final SyncableValue<String> title = syncableValue('title', '');
  late final SyncableValue<int> count = syncableValue('count', 0);
  late final SyncableList<String> tags = syncableList('tags');
  late final _Child child = syncableChild('child', _Child(nodeId));
  late final SyncableNodeList<_Child> items =
      syncableNodeList('items', () => _Child(nodeId));

  void warmUp() {
    title;
    count;
    tags;
    child.label;
    items;
  }
}

class _Note extends Syncable {
  _Note(super.nodeId);

  late final SyncableValue<String> text = syncableValue('text', '');
}

class _TypedSource extends Syncable {
  _TypedSource(super.nodeId);

  late final SyncableNodeList<Syncable> feed = syncableTypedNodeList('feed', {
    'note': () => _Note(nodeId),
  });

  void warmUp() {
    feed;
  }
}

void main() {
  group('DynamicSyncable', () {
    test('materializes values, lists, children, and node lists', () async {
      final source = _Source('src')..warmUp();
      final dyn = DynamicSyncable('observer');
      final sub = source.onPropertyChange.listen(dyn.applyRemoteChange);

      source.title.value = 'hello';
      source.count.value = 3;
      source.tags.add('a');
      source.tags.add('b');
      source.child.label.value = 'nested';
      final item = source.items.add();
      item.label.value = 'card-1';

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(dyn.toJson(), {
        'title': 'hello',
        'count': 3,
        'tags': ['a', 'b'],
        'child': {'label': 'nested'},
        'items': [
          {'label': 'card-1'},
        ],
      });
    });

    test('LWW still applies through materialization', () {
      final dyn = DynamicSyncable('observer');
      dyn.applyRemoteChange(
        const ValueSetChange<String>(
          propertyKey: 'title',
          nodeId: 'a',
          lamportClock: 1,
          value: 'first',
        ),
      );
      dyn.applyRemoteChange(
        const ValueSetChange<String>(
          propertyKey: 'title',
          nodeId: 'b',
          lamportClock: 2,
          value: 'second',
        ),
      );
      dyn.applyRemoteChange(
        const ValueSetChange<String>(
          propertyKey: 'title',
          nodeId: 'c',
          lamportClock: 1,
          value: 'stale',
        ),
      );

      expect(dyn.toJson(), {'title': 'second'});
    });

    test('observes typed node-list inserts without domain factories', () async {
      final source = _TypedSource('src')..warmUp();
      final dyn = DynamicSyncable('observer');
      final sub = source.onPropertyChange.listen(dyn.applyRemoteChange);

      final note = source.feed.add('note') as _Note;
      note.text.value = 'typed-body';

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(dyn.toJson(), {
        'feed': [
          {'text': 'typed-body'},
        ],
      });
    });

    test('Syncable.toJson works on ordinary models', () {
      final source = _Source('src')..warmUp();
      source.title.value = 'plain';
      source.tags.add('x');
      source.child.label.value = 'y';

      expect(source.toJson(), {
        'title': 'plain',
        'count': 0,
        'tags': ['x'],
        'child': {'label': 'y'},
        'items': <Map<String, Object?>>[],
      });
    });

    test('applyJson round-trips toJson for nested documents', () async {
      final source = _Source('src')..warmUp();
      final captured = DynamicSyncable('capture');
      final sub = source.onPropertyChange.listen(captured.applyRemoteChange);

      source.title.value = 'hello';
      source.count.value = 3;
      source.tags.add('a');
      source.tags.add('b');
      source.child.label.value = 'nested';
      final item = source.items.add();
      item.label.value = 'card-1';
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final restored = DynamicSyncable('restored');
      restored.applyJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(captured.toJson())) as Map,
        ),
      );

      expect(restored.toJson(), captured.toJson());
    });
  });
}
