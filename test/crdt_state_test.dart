import 'package:flutter_test/flutter_test.dart';
import 'package:syncable/syncable.dart';


class _Board extends Syncable {
  _Board(super.nodeId) {
    // Eagerly register late properties so applyCrdtJson can hydrate.
    name;
    tags;
    cards;
    feed;
  }

  late final SyncableValue<String> name = syncableValue('name', '');
  late final SyncableList<String> tags = syncableList('tags');
  late final SyncableNodeList<_CardEager> cards =
      syncableNodeList('cards', () => _CardEager(nodeId));
  late final SyncableNodeList<Syncable> feed = syncableTypedNodeList('feed', {
    'card': () => _CardEager(nodeId),
  });
}

class _CardEager extends Syncable {
  _CardEager(super.nodeId) {
    title;
  }

  late final SyncableValue<String> title = syncableValue('title', '');
}

void main() {
  group('toCrdtJson / applyCrdtJson', () {
    test('round-trips values, lists, clocks, and element ids', () {
      final source = _Board('alice');
      source.name.value = 'Project';
      source.tags.add('a');
      source.tags.add('b');
      source.tags.removeAt(0);
      final card = source.cards.add();
      card.title.value = 'One';

      final json = source.toCrdtJson();
      expect(json['format'], 'syncable_crdt_v1');
      expect(json['lamportClock'], source.lamportClock);

      final restored = _Board('bob');
      final emissions = <SyncableChange>[];
      restored.onPropertyChange.listen(emissions.add);
      restored.applyCrdtJson(Map<String, dynamic>.from(json));

      expect(emissions, isEmpty);
      expect(restored.name.value, 'Project');
      expect(restored.tags.toList(), ['b']);
      expect(restored.cards.length, 1);
      expect(restored.cards.first.title.value, 'One');
      expect(restored.lamportClock, source.lamportClock);
      expect(restored.toCrdtJson(), json);
    });

    test('silent apply does not emit on DynamicSyncable', () {
      final source = DynamicSyncable('alice');
      source.syncableValue('title', '').value = 'hi';
      source.syncableList('tags').add('x');

      final restored = DynamicSyncable('bob');
      final emissions = <SyncableChange>[];
      restored.onPropertyChange.listen(emissions.add);
      restored.applyCrdtJson(source.toCrdtJson());

      expect(emissions, isEmpty);
      expect(restored.toJson(), {'title': 'hi', 'tags': ['x']});
    });

    test('RGA continuity: remote remove by pre-snapshot element id works', () {
      final source = _Board('alice');
      source.tags.add('keep');
      source.tags.add('drop');
      final snapshot = source.toCrdtJson();

      final props = snapshot['properties'] as Map;
      final tags = props['tags'] as Map;
      final entries = tags['entries'] as List;
      final dropId = (entries[1] as Map)['id'] as String;

      final restored = _Board('bob');
      restored.applyCrdtJson(Map<String, dynamic>.from(snapshot));
      expect(restored.tags.toList(), ['keep', 'drop']);

      restored.applyRemoteChange(
        ListRemoveChange<String>(
          propertyKey: 'tags',
          nodeId: 'alice',
          lamportClock: restored.lamportClock + 1,
          elementId: ElementId(
            dropId.substring(0, dropId.lastIndexOf(':')),
            int.parse(dropId.substring(dropId.lastIndexOf(':') + 1)),
          ),
        ),
      );
      expect(restored.tags.toList(), ['keep']);
    });

    test('LWW equal-clock tie uses persisted writerNodeId', () {
      final source = _Board('zzz');
      source.name.value = 'from-zzz';
      final json = source.toCrdtJson();

      final restored = _Board('aaa');
      restored.applyCrdtJson(Map<String, dynamic>.from(json));
      expect(restored.name.value, 'from-zzz');

      // Equal clock, writer "mmm" < stored "zzz" → lose.
      restored.applyRemoteChange(
        ValueSetChange<String>(
          propertyKey: 'name',
          nodeId: 'mmm',
          lamportClock: 1,
          value: 'from-mmm',
        ),
      );
      expect(restored.name.value, 'from-zzz');

      // Equal clock, writer "zzz2" > stored "zzz" → win.
      restored.applyRemoteChange(
        ValueSetChange<String>(
          propertyKey: 'name',
          nodeId: 'zzz2',
          lamportClock: 1,
          value: 'from-zzz2',
        ),
      );
      expect(restored.name.value, 'from-zzz2');
    });

    test('typed node list typeId survives round-trip', () {
      final source = _Board('alice');
      final card = source.feed.add('card') as _CardEager;
      card.title.value = 'typed';

      final json = source.toCrdtJson();
      final feed = (json['properties'] as Map)['feed'] as Map;
      final entry = (feed['entries'] as List).first as Map;
      expect(entry['typeId'], 'card');

      final restored = _Board('bob');
      restored.applyCrdtJson(Map<String, dynamic>.from(json));
      expect(restored.feed.length, 1);
      expect(restored.feed.first, isA<_CardEager>());
      expect((restored.feed.first as _CardEager).title.value, 'typed');

      final restoredFeed = (restored.toCrdtJson()['properties'] as Map)['feed'] as Map;
      expect((restoredFeed['entries'] as List).first['typeId'], 'card');
    });

    test('tombstoned list entries are preserved in dump', () {
      final source = _Board('alice');
      source.tags.add('gone');
      source.tags.removeAt(0);
      final json = source.toCrdtJson();
      final tags = (json['properties'] as Map)['tags'] as Map;
      final entries = tags['entries'] as List;
      expect(entries.length, 1);
      expect(entries.first['tombstone'], isTrue);
      expect(entries.first['value'], 'gone');
    });
  });
}
