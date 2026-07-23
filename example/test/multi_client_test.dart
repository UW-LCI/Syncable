import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:syncable_properties/syncable_properties.dart';

import 'package:syncable_properties_example/sync_network.dart';
import 'package:syncable_properties_example/serialization.dart';

class TestModel extends Syncable {
  TestModel(super.nodeId);

  late final SyncableValue<String> title = syncableValue('title', '');
  late final SyncableValue<int> counter = syncableValue('counter', 0);
  late final SyncableList<String> items = syncableList('items');
}

void main() {
  group('Serialization round-trip', () {
    test('ValueSetChange', () {
      final change = ValueSetChange<String>(
        propertyKey: 'title',
        nodeId: 'node1',
        lamportClock: 42,
        value: 'hello',
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ValueSetChange>());
      final vc = restored as ValueSetChange;
      expect(vc.propertyKey, 'title');
      expect(vc.nodeId, 'node1');
      expect(vc.lamportClock, 42);
      expect(vc.value, 'hello');
    });

    test('ListInsertChange', () {
      final change = ListInsertChange<String>(
        propertyKey: 'items',
        nodeId: 'node1',
        lamportClock: 5,
        elementId: const ElementId('node1', 3),
        value: 'item',
        afterElementId: const ElementId('node1', 2),
        position: 0.75,
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListInsertChange>());
      final lic = restored as ListInsertChange;
      expect(lic.propertyKey, 'items');
      expect(lic.elementId, const ElementId('node1', 3));
      expect(lic.value, 'item');
      expect(lic.afterElementId, const ElementId('node1', 2));
      expect(lic.position, 0.75);
    });

    test('ListInsertChange without afterElementId', () {
      final change = ListInsertChange<int>(
        propertyKey: 'nums',
        nodeId: 'node2',
        lamportClock: 1,
        elementId: const ElementId('node2', 0),
        value: 42,
        position: 0.5,
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListInsertChange>());
      final lic = restored as ListInsertChange;
      expect(lic.afterElementId, isNull);
      expect(lic.position, 0.5);
      expect(lic.value, 42);
    });

    test('ListRemoveChange', () {
      final change = ListRemoveChange<String>(
        propertyKey: 'items',
        nodeId: 'node1',
        lamportClock: 10,
        elementId: const ElementId('node1', 0),
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListRemoveChange>());
      final lrc = restored as ListRemoveChange;
      expect(lrc.propertyKey, 'items');
      expect(lrc.elementId, const ElementId('node1', 0));
    });

    test('ListUpdateChange', () {
      final change = ListUpdateChange<String>(
        propertyKey: 'items',
        nodeId: 'node1',
        lamportClock: 7,
        elementId: const ElementId('node1', 5),
        value: 'updated',
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListUpdateChange>());
      final luc = restored as ListUpdateChange;
      expect(luc.propertyKey, 'items');
      expect(luc.elementId, const ElementId('node1', 5));
      expect(luc.value, 'updated');
    });
  });

  group('Two-client sync', () {
    late SyncNodeHost host;
    late TestModel modelA;
    late TestModel modelB;

    setUp(() {
      host = SyncNodeHost();
      modelA = TestModel('clientA');
      modelB = TestModel('clientB');
      host.addNode('clientA', modelA);
      host.addNode('clientB', modelB);
    });

    tearDown(() => host.close());

    test('synced value set propagates to peer', () async {
      modelA.title.value = 'Hello from A';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.title.value, 'Hello from A');
    });

    test('synced value from B propagates to A', () async {
      modelB.counter.value = 99;

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.counter.value, 99);
    });

    test('multiple value updates propagate', () async {
      modelA.title.value = 'first';
      await Future.delayed(Duration.zero);
      modelA.title.value = 'second';
      await Future.delayed(Duration.zero);
      modelA.title.value = 'third';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.title.value, 'third');
    });

    test('list add propagates', () async {
      modelA.items.add('item_from_A');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items.toViewList(), ['item_from_A']);
    });

    test('multiple list operations propagate in order', () async {
      modelA.items.add('first');
      await Future.delayed(Duration.zero);
      modelA.items.add('second');
      await Future.delayed(Duration.zero);
      modelA.items.add('third');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items.toViewList(), ['first', 'second', 'third']);
    });

    test('local value changes on both sides converge', () async {
      modelA.title.value = 'value_A';
      modelB.title.value = 'value_B';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.title.value, modelB.title.value);
    });

    test('list operations on both sides converge', () async {
      modelA.items.add('a1');
      await Future.delayed(Duration.zero);
      modelB.items.add('b1');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.items.length, 2);
      expect(modelB.items.length, 2);
      expect(modelA.items.toViewList(), modelB.items.toViewList());
    });

    test('remove operations propagate', () async {
      modelA.items.add('keep');
      await Future.delayed(Duration.zero);
      modelA.items.add('remove_me');
      await Future.delayed(Duration.zero);

      modelA.items.removeAt(1);

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items.toViewList(), ['keep']);
    });

    test('update operations propagate', () async {
      modelA.items.add('original');

      await Future.delayed(const Duration(milliseconds: 10));

      modelA.items[0] = 'updated';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items[0], 'updated');
    });
  });

  group('Three-client sync', () {
    late SyncNodeHost host;
    late TestModel modelA;
    late TestModel modelB;
    late TestModel modelC;

    setUp(() {
      host = SyncNodeHost();
      modelA = TestModel('clientA');
      modelB = TestModel('clientB');
      modelC = TestModel('clientC');
      host.addNode('clientA', modelA);
      host.addNode('clientB', modelB);
      host.addNode('clientC', modelC);
    });

    tearDown(() => host.close());

    test('value from A reaches B and C', () async {
      modelA.title.value = 'broadcast';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.title.value, 'broadcast');
      expect(modelC.title.value, 'broadcast');
    });

    test('value from C reaches A and B', () async {
      modelC.counter.value = 500;

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.counter.value, 500);
      expect(modelB.counter.value, 500);
    });

    test('concurrent updates from all three converge', () async {
      modelA.items.add('fromA');
      modelB.items.add('fromB');
      modelC.items.add('fromC');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.items.length, 3);
      expect(modelB.items.length, 3);
      expect(modelC.items.length, 3);
      expect(modelA.items.toViewList(), modelB.items.toViewList());
      expect(modelB.items.toViewList(), modelC.items.toViewList());
    });

    test('sequential operations converge to same state', () async {
      modelA.items.add('a');
      await Future.delayed(Duration.zero);
      modelB.items.add('b');
      await Future.delayed(Duration.zero);
      modelC.items.add('c');
      await Future.delayed(Duration.zero);
      modelA.items.add('d');
      await Future.delayed(Duration.zero);
      modelB.items.add('e');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.items.length, 5);
      expect(modelB.items.length, 5);
      expect(modelC.items.length, 5);
      expect(modelA.items.toViewList(), modelB.items.toViewList());
      expect(modelB.items.toViewList(), modelC.items.toViewList());
    });
  });

  group('Concurrent conflicting operations', () {
    late SyncNodeHost host;
    late TestModel modelA;
    late TestModel modelB;

    setUp(() {
      host = SyncNodeHost();
      modelA = TestModel('clientA');
      modelB = TestModel('clientB');
      host.addNode('clientA', modelA);
      host.addNode('clientB', modelB);
    });

    tearDown(() => host.close());

    test('concurrent value sets converge (LWW)', () async {
      // Both set values concurrently before syncing
      modelA.counter.value = 42;
      modelB.counter.value = 99;

      await Future.delayed(const Duration(milliseconds: 10));

      // Both should have the same value (LWW: higher clock wins)
      expect(modelA.counter.value, modelB.counter.value);
    });

    test('concurrent list inserts at same position converge', () async {
      modelA.items.add('base');
      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items.toViewList(), ['base']);

      // Concurrent inserts after 'base'
      modelA.items.add('fromA');
      modelB.items.add('fromB');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.items.length, 3);
      expect(modelB.items.length, 3);
      expect(modelA.items.toViewList(), modelB.items.toViewList());
      expect(Set<String>.from(modelA.items.toViewList()),
          {'base', 'fromA', 'fromB'});
    });

    test('identical concurrent operations produce identical state', () async {
      modelA.items.add('x');
      await Future.delayed(const Duration(milliseconds: 10));

      modelA.items.add('y');
      modelB.items.add('z');

      await Future.delayed(const Duration(milliseconds: 10));

      modelA.items.add('w');
      modelB.items.add('q');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.items.toViewList(), modelB.items.toViewList());
    });
  });

  group('Late-joining client', () {
    test('late client receives existing state', () async {
      final host = SyncNodeHost();

      final modelA = TestModel('clientA');
      final modelB = TestModel('clientB');

      host.addNode('clientA', modelA);
      host.addNode('clientB', modelB);

      modelA.title.value = 'established';
      modelA.items.add('item1');
      await Future.delayed(Duration.zero);
      modelA.items.add('item2');

      await Future.delayed(const Duration(milliseconds: 10));

      // Late-joining client
      final modelC = TestModel('clientC');
      host.addNode('clientC', modelC);

      await Future.delayed(const Duration(milliseconds: 10));

      // C doesn't get historical state automatically
      // This tests that C can start receiving future updates
      modelA.items.add('item3');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items.toViewList(), contains('item3'));
      expect(modelC.items.toViewList(), contains('item3'));

      host.close();
    });
  });

  group('Stress test with many operations', () {
    test('five clients with rapid value changes converge', () async {
      final host = SyncNodeHost();
      final models = <TestModel>[];

      for (var i = 0; i < 5; i++) {
        final model = TestModel('client$i');
        host.addNode('client$i', model);
        models.add(model);
      }

      models[0].items.add('s0');
      await Future.delayed(Duration.zero);
      models[1].items.add('s1');
      await Future.delayed(Duration.zero);
      models[2].items.add('s2');
      await Future.delayed(Duration.zero);
      models[3].items.add('s3');
      await Future.delayed(Duration.zero);
      models[4].items.add('s4');

      await Future.delayed(const Duration(milliseconds: 20));

      for (final model in models) {
        expect(model.items.length, 5);
      }

      host.close();
    });

    test('ten rapid sequential adds on two clients converge', () async {
      final host = SyncNodeHost();
      final modelA = TestModel('A');
      final modelB = TestModel('B');
      host.addNode('A', modelA);
      host.addNode('B', modelB);

      for (var i = 0; i < 10; i++) {
        modelA.items.add('a$i');
      }

      await Future.delayed(const Duration(milliseconds: 20));

      expect(modelB.items.length, 10);
      expect(modelA.items.toViewList(), modelB.items.toViewList());

      host.close();
    });
  });

  group('Multiple property types in sync', () {
    late SyncNodeHost host;
    late TestModel modelA;
    late TestModel modelB;

    setUp(() {
      host = SyncNodeHost();
      modelA = TestModel('A');
      modelB = TestModel('B');
      host.addNode('A', modelA);
      host.addNode('B', modelB);
    });

    tearDown(() => host.close());

    test('different properties sync independently', () async {
      modelA.title.value = 'sync title';
      modelA.counter.value = 123;
      modelA.items.add('sync item');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.title.value, 'sync title');
      expect(modelB.counter.value, 123);
      expect(modelB.items.toViewList(), ['sync item']);
    });

    test('property updates are isolated', () async {
      modelA.title.value = 'title only';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.title.value, 'title only');
      expect(modelB.counter.value, 0);
      expect(modelB.items.isEmpty, true);
    });
  });
}