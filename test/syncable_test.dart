import 'package:flutter_test/flutter_test.dart';

import 'package:syncable_properties/syncable_properties.dart';

class TestModel extends Syncable {
  TestModel(super.nodeId);

  late final SyncableValue<int> count = syncableValue('count', 0);
  late final SyncableValue<String> label = syncableValue('label', '');
  late final SyncableList<String> items = syncableList('items');
}

void main() {
  group('SyncableValue (LWW Register)', () {
    test('initial value', () {
      final model = TestModel('device1');
      expect(model.count.value, 0);
      expect(model.label.value, '');
    });

    test('local set updates value and clock', () {
      final model = TestModel('device1');
      final initialClock = model.lamportClock;

      model.count.value = 42;

      expect(model.count.value, 42);
      expect(model.lamportClock, greaterThan(initialClock));
    });

    test('emits change on local set', () async {
      final model = TestModel('device1');
      final future = model.onPropertyChange.first;

      model.count.value = 42;

      final change = await future;
      expect(change, isA<ValueSetChange<int>>());
      final vc = change as ValueSetChange<int>;
      expect(vc.propertyKey, 'count');
      expect(vc.nodeId, 'device1');
      expect(vc.value, 42);
      expect(vc.lamportClock, greaterThan(0));
    });

    test('LWW: higher clock wins', () {
      final model = TestModel('device1');

      model.applyRemoteChange(
        ValueSetChange<int>(
          propertyKey: 'count',
          nodeId: 'device2',
          lamportClock: 100,
          value: 99,
        ),
      );

      expect(model.count.value, 99);
    });

    test('LWW: older clock does not overwrite', () {
      final model = TestModel('device1');
      model.count.value = 10;
      final currentClock = model.lamportClock;

      model.applyRemoteChange(
        ValueSetChange<int>(
          propertyKey: 'count',
          nodeId: 'device2',
          lamportClock: currentClock - 1,
          value: 99,
        ),
      );

      expect(model.count.value, 10);
    });

    test('LWW: tie broken by nodeId (higher nodeId wins)', () {
      final model = TestModel('device1');
      model.count.value = 42; // clock = 1

      model.applyRemoteChange(
        ValueSetChange<int>(
          propertyKey: 'count',
          nodeId: 'device2',
          lamportClock: 1,
          value: 99,
        ),
      );

      expect(model.count.value, 99);
    });

    test('LWW: tie broken by nodeId (lower nodeId loses)', () {
      final model = TestModel('device2');
      model.count.value = 42; // clock = 1

      model.applyRemoteChange(
        ValueSetChange<int>(
          propertyKey: 'count',
          nodeId: 'device1',
          lamportClock: 1,
          value: 99,
        ),
      );

      expect(model.count.value, 42);
    });
  });

  group('SyncableList (RGA CRDT)', () {
    test('starts empty', () {
      final model = TestModel('device1');
      expect(model.items.length, 0);
      expect(model.items.isEmpty, true);
      expect(model.items.isNotEmpty, false);
    });

    test('add appends items', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      model.items.add('c');

      expect(model.items.toViewList(), ['a', 'b', 'c']);
      expect(model.items.length, 3);
    });

    test('insert at beginning', () {
      final model = TestModel('device1');
      model.items.add('b');
      model.items.add('c');
      model.items.insert(0, 'a');

      expect(model.items.toViewList(), ['a', 'b', 'c']);
    });

    test('insert in middle', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('c');
      model.items.insert(1, 'b');

      expect(model.items.toViewList(), ['a', 'b', 'c']);
    });

    test('insert at end', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.insert(1, 'b');

      expect(model.items.toViewList(), ['a', 'b']);
    });

    test('operator [] access', () {
      final model = TestModel('device1');
      model.items.add('x');
      model.items.add('y');
      model.items.add('z');

      expect(model.items[0], 'x');
      expect(model.items[1], 'y');
      expect(model.items[2], 'z');
    });

    test('operator []= update emits change', () async {
      final model = TestModel('device1');
      model.items.add('old');
      final future = model.onPropertyChange.first;

      model.items[0] = 'new';

      final change = await future;
      expect(model.items[0], 'new');
      expect(change, isA<ListUpdateChange<String>>());
      final uc = change as ListUpdateChange<String>;
      expect(uc.value, 'new');
    });

    test('removeAt', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      model.items.add('c');

      model.items.removeAt(1);

      expect(model.items.toViewList(), ['a', 'c']);
      expect(model.items.length, 2);
    });

    test('removeAt from beginning', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      model.items.removeAt(0);

      expect(model.items.toViewList(), ['b']);
    });

    test('removeAt from end', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      model.items.removeAt(1);

      expect(model.items.toViewList(), ['a']);
    });

    test('add emits ListInsertChange', () async {
      final model = TestModel('device1');
      final future = model.onPropertyChange.first;

      model.items.add('hello');

      final change = await future;
      expect(change, isA<ListInsertChange<String>>());
      final ic = change as ListInsertChange<String>;
      expect(ic.propertyKey, 'items');
      expect(ic.nodeId, 'device1');
      expect(ic.value, 'hello');
      expect(ic.afterElementId, isNull);
      expect(ic.elementId.nodeId, 'device1');
    });

    test('removeAt emits ListRemoveChange', () async {
      final model = TestModel('device1');
      model.items.add('x');
      final future = model.onPropertyChange.first;

      model.items.removeAt(0);

      final change = await future;
      expect(change, isA<ListRemoveChange<String>>());
      expect((change as ListRemoveChange<String>).propertyKey, 'items');
    });

    test('out of range throws', () {
      final model = TestModel('device1');
      model.items.add('a');

      expect(() => model.items.removeAt(5), throwsA(isA<RangeError>()));
    });

    test('first and last', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      model.items.add('c');

      expect(model.items.first, 'a');
      expect(model.items.last, 'c');
    });

    test('single', () {
      final model = TestModel('device1');
      model.items.add('only');

      expect(model.items.single, 'only');
    });

    test('single throws when empty', () {
      final model = TestModel('device1');
      expect(() => model.items.single, throwsA(isA<StateError>()));
    });

    test('single throws when multiple', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      expect(() => model.items.single, throwsA(isA<StateError>()));
    });

    test('iteration', () {
      final model = TestModel('device1');
      model.items.add('a');
      model.items.add('b');
      model.items.add('c');

      final collected = <String>[];
      for (final item in model.items) {
        collected.add(item);
      }

      expect(collected, ['a', 'b', 'c']);
    });

    test('applying remote list insert', () {
      final model = TestModel('device1');
      model.applyRemoteChange(
        ListInsertChange<String>(
          propertyKey: 'items',
          nodeId: 'device2',
          lamportClock: 5,
          elementId: const ElementId('device2', 0),
          value: 'remote_item',
          afterElementId: null,
          position: 0.5,
        ),
      );

      expect(model.items.toViewList(), ['remote_item']);
    });

    test('applying remote list remove', () {
      final model = TestModel('device1');
      final elementId = const ElementId('device2', 0);
      model.applyRemoteChange(
        ListInsertChange<String>(
          propertyKey: 'items',
          nodeId: 'device2',
          lamportClock: 1,
          elementId: elementId,
          value: 'will_be_removed',
          afterElementId: null,
          position: 0.5,
        ),
      );

      model.applyRemoteChange(
        ListRemoveChange<String>(
          propertyKey: 'items',
          nodeId: 'device2',
          lamportClock: 2,
          elementId: elementId,
        ),
      );

      expect(model.items.isEmpty, true);
    });

    test('applying remote list update', () {
      final model = TestModel('device1');
      final elementId = const ElementId('device2', 0);
      model.applyRemoteChange(
        ListInsertChange<String>(
          propertyKey: 'items',
          nodeId: 'device2',
          lamportClock: 1,
          elementId: elementId,
          value: 'original',
          afterElementId: null,
          position: 0.5,
        ),
      );

      model.applyRemoteChange(
        ListUpdateChange<String>(
          propertyKey: 'items',
          nodeId: 'device2',
          lamportClock: 2,
          elementId: elementId,
          value: 'updated',
        ),
      );

      expect(model.items.toViewList(), ['updated']);
    });
  });

  group('Concurrent list operations', () {
    test('concurrent inserts at same position converge', () {
      final modelA = TestModel('A');
      final modelB = TestModel('B');

      final changesA = <SyncableChange>[];
      final changesB = <SyncableChange>[];
      modelA.onPropertyChange.listen(changesA.add);
      modelB.onPropertyChange.listen(changesB.add);

      modelA.items.add('base');

      final insertBase = changesA[0] as ListInsertChange<String>;
      modelB.applyRemoteChange(insertBase);

      expect(modelA.items.toViewList(), ['base']);
      expect(modelB.items.toViewList(), ['base']);

      changesA.clear();

      modelA.items.add('concurrentA');
      modelB.items.add('concurrentB');

      final insertA = changesA[0] as ListInsertChange<String>;
      final insertB = changesB[0] as ListInsertChange<String>;

      modelB.applyRemoteChange(insertA);
      modelA.applyRemoteChange(insertB);

      final finalA = modelA.items.toViewList();
      final finalB = modelB.items.toViewList();

      expect(finalA.length, 3);
      expect(finalB.length, 3);
      expect(finalA, finalB);
      expect(Set<String>.from(finalA), {'base', 'concurrentA', 'concurrentB'});
    });

    test('concurrent operations applied in different order converge', () {
      final model1 = TestModel('r1');
      final model2 = TestModel('r2');

      final m1Changes = <SyncableChange>[];
      final m2Changes = <SyncableChange>[];
      model1.onPropertyChange.listen(m1Changes.add);
      model2.onPropertyChange.listen(m2Changes.add);

      model1.items.add('x');

      final insertX = m1Changes[0] as ListInsertChange<String>;
      model2.applyRemoteChange(insertX);

      expect(model1.items.toViewList(), ['x']);
      expect(model2.items.toViewList(), ['x']);

      m1Changes.clear();

      model1.items.add('a');
      model2.items.add('b');

      final insertA = m1Changes[0] as ListInsertChange<String>;
      final insertB = m2Changes[0] as ListInsertChange<String>;

      model2.applyRemoteChange(insertA);
      model1.applyRemoteChange(insertB);

      expect(model1.items.toViewList(), model2.items.toViewList());
    });
  });

  group('Syncable base class', () {
    test('unique nodeId per instance', () {
      final model1 = TestModel('nodeA');
      final model2 = TestModel('nodeB');

      expect(model1.nodeId, 'nodeA');
      expect(model2.nodeId, 'nodeB');
    });

    test('lamportClock increments on local operations', () {
      final model = TestModel('device1');
      expect(model.lamportClock, 0);

      model.count.value = 1;
      expect(model.lamportClock, 1);

      model.count.value = 2;
      expect(model.lamportClock, 2);
    });

    test('lamportClock updated on remote changes', () {
      final model = TestModel('device1');
      model.count.value = 1;
      expect(model.lamportClock, 1);

      model.applyRemoteChange(
        ValueSetChange<int>(
          propertyKey: 'count',
          nodeId: 'device2',
          lamportClock: 50,
          value: 99,
        ),
      );

      expect(model.lamportClock, 51);
    });

    test('dispose closes stream', () async {
      final model = TestModel('device1');
      model.dispose();

      // After dispose, the stream should be closed
      final sub = model.onPropertyChange.listen((_) {});
      await null; // Let the subscription be processed
      sub.cancel();
    });
  });

  group('Subclassing', () {
    test('subclasses maintain syncing', () {
      final model = TestModel('device1');
      model.count.value = 42;
      model.items.add('item');

      expect(model.count.value, 42);
      expect(model.items.toViewList(), ['item']);
    });

    test('multiple properties work independently', () {
      final model = TestModel('device1');
      model.count.value = 5;
      model.label.value = 'test';

      model.applyRemoteChange(
        ValueSetChange<int>(
          propertyKey: 'count',
          nodeId: 'device2',
          lamportClock: 100,
          value: 999,
        ),
      );

      expect(model.count.value, 999);
      expect(model.label.value, 'test');
    });
  });

  group('ElementId', () {
    test('equality', () {
      expect(
        const ElementId('a', 1),
        const ElementId('a', 1),
      );
      expect(
        const ElementId('a', 1),
        isNot(const ElementId('a', 2)),
      );
      expect(
        const ElementId('a', 1),
        isNot(const ElementId('b', 1)),
      );
    });

    test('comparison', () {
      final ids = [
        const ElementId('b', 1),
        const ElementId('a', 2),
        const ElementId('a', 1),
        const ElementId('b', 0),
      ];
      ids.sort();

      expect(ids, [
        const ElementId('a', 1),
        const ElementId('a', 2),
        const ElementId('b', 0),
        const ElementId('b', 1),
      ]);
    });

    test('toString', () {
      expect(const ElementId('dev', 5).toString(), 'dev:5');
    });
  });
}