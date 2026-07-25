import 'package:flutter_test/flutter_test.dart';
import 'package:syncable_properties/syncable_properties.dart';

class TestModel extends Syncable {
  TestModel(super.nodeId);

  late final SyncableValue<String> title = syncableValue('title', '');
  late final SyncableValue<int> counter = syncableValue('counter', 0);
  late final SyncableList<String> items = syncableList('items');
}

void main() {
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
      modelA.counter.value = 42;
      modelB.counter.value = 99;

      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelA.counter.value, modelB.counter.value);
    });

    test('concurrent list inserts at same position converge', () async {
      modelA.items.add('base');
      await Future.delayed(const Duration(milliseconds: 10));

      expect(modelB.items.toViewList(), ['base']);

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
    test('late client receives subsequent updates', () async {
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

      final modelC = TestModel('clientC');
      host.addNode('clientC', modelC);

      await Future.delayed(const Duration(milliseconds: 10));

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

  group('DocumentSyncHost', () {
    test('routes edits by instance id', () async {
      final host = DocumentSyncHost();
      final a1 = TestModel('clientA');
      final a2 = TestModel('clientA');
      final b1 = TestModel('clientB');
      final b2 = TestModel('clientB');

      host.addDocument('clientA', 'doc1', a1);
      host.addDocument('clientA', 'doc2', a2);
      host.addDocument('clientB', 'doc1', b1);
      host.addDocument('clientB', 'doc2', b2);

      a1.title.value = 'only-doc1';
      await Future.delayed(const Duration(milliseconds: 10));

      expect(b1.title.value, 'only-doc1');
      expect(b2.title.value, '');
      expect(a2.title.value, '');

      host.close();
    });
  });
}
