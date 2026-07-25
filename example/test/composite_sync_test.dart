import 'package:test/test.dart';
import 'package:syncable_properties/syncable_properties.dart';

import 'package:syncable_properties_example/models.dart';

void main() {
  group('Composite sync over the network', () {
    late SyncNodeHost host;
    late Board boardA;
    late Board boardB;

    setUp(() {
      host = SyncNodeHost();
      boardA = Board('clientA')..register();
      boardB = Board('clientB')..register();
      host.addNode('clientA', boardA);
      host.addNode('clientB', boardB);
    });

    tearDown(() => host.close());

    test('nested child value propagates through serialization', () async {
      boardA.owner.name.value = 'Ada';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(boardB.owner.name.value, 'Ada');
    });

    test('primitive list inside a child propagates', () async {
      final card = boardA.cards.add();
      card.labels.add('math');
      await Future.delayed(Duration.zero);
      card.labels.add('cs');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(boardB.cards[0].labels.toViewList(), ['math', 'cs']);
    });

    test('a Syncable list element plus its edits propagate', () async {
      final card = boardA.cards.add();
      card.title.value = 'ship it';
      card.done.value = true;

      await Future.delayed(const Duration(milliseconds: 10));

      expect(boardB.cards.length, 1);
      expect(boardB.cards[0].title.value, 'ship it');
      expect(boardB.cards[0].done.value, true);
    });

    test('removing a list element propagates', () async {
      final c0 = boardA.cards.add();
      c0.title.value = 'keep';
      final c1 = boardA.cards.add();
      c1.title.value = 'drop';

      await Future.delayed(const Duration(milliseconds: 10));
      expect(boardB.cards.length, 2);

      boardA.cards.removeAt(1);

      await Future.delayed(const Duration(milliseconds: 10));
      expect(boardB.cards.length, 1);
      expect(boardB.cards[0].title.value, 'keep');
    });

    test('concurrent element inserts converge across the wire', () async {
      final ca = boardA.cards.add();
      ca.title.value = 'A-task';
      final cb = boardB.cards.add();
      cb.title.value = 'B-task';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(boardA.cards.length, 2);
      expect(boardB.cards.length, 2);
      expect(
        boardA.cards.map((c) => c.title.value).toList(),
        boardB.cards.map((c) => c.title.value).toList(),
      );
      expect(
        boardA.cards.map((c) => c.title.value).toSet(),
        {'A-task', 'B-task'},
      );
    });

    test('editing a synced element from the peer propagates back', () async {
      final card = boardA.cards.add();
      card.title.value = 'v1';
      await Future.delayed(const Duration(milliseconds: 10));
      expect(boardB.cards[0].title.value, 'v1');

      boardB.cards[0].done.value = true;
      await Future.delayed(const Duration(milliseconds: 10));
      expect(boardA.cards[0].done.value, true);
    });

    test('top-level and nested edits stay independent', () async {
      boardA.name.value = 'Report';
      boardA.owner.name.value = 'Grace';
      final card = boardA.cards.add();
      card.title.value = 'review';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(boardB.name.value, 'Report');
      expect(boardB.owner.name.value, 'Grace');
      expect(boardB.cards[0].title.value, 'review');
    });
  });

  group('Typed node list over the network', () {
    late SyncNodeHost host;
    late Feed feedA;
    late Feed feedB;

    setUp(() {
      host = SyncNodeHost();
      feedA = Feed('clientA')..register();
      feedB = Feed('clientB')..register();
      host.addNode('clientA', feedA);
      host.addNode('clientB', feedB);
    });

    tearDown(() => host.close());

    test('mixed element subtypes rebuild correctly on the peer', () async {
      final note = feedA.items.add('note') as NoteItem;
      note.text.value = 'remember the milk';
      final link = feedA.items.add('link') as LinkItem;
      link.url.value = 'https://dart.dev';
      link.caption.value = 'Dart';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(feedB.items.length, 2);
      expect(feedB.items[0], isA<NoteItem>());
      expect((feedB.items[0] as NoteItem).text.value, 'remember the milk');
      expect(feedB.items[1], isA<LinkItem>());
      expect((feedB.items[1] as LinkItem).url.value, 'https://dart.dev');
      expect((feedB.items[1] as LinkItem).caption.value, 'Dart');
    });
  });

  group('Multiple root Boards across nodes', () {
    late DocumentSyncHost host;
    late Board a1, a2, a3;
    late Board b1, b2, b3;

    setUp(() {
      host = DocumentSyncHost(
        factory: (nodeId, _) => Board(nodeId)..register(),
      );

      a1 = Board('clientA')..register();
      a2 = Board('clientA')..register();
      a3 = Board('clientA')..register();
      b1 = Board('clientB')..register();
      b2 = Board('clientB')..register();
      b3 = Board('clientB')..register();

      host.addDocument('clientA', 'proj1', a1);
      host.addDocument('clientA', 'proj2', a2);
      host.addDocument('clientA', 'proj3', a3);
      host.addDocument('clientB', 'proj1', b1);
      host.addDocument('clientB', 'proj2', b2);
      host.addDocument('clientB', 'proj3', b3);
    });

    tearDown(() => host.close());

    test('editing one board updates only that board on the peer', () async {
      a1.name.value = 'Alpha';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(b1.name.value, 'Alpha');
      expect(b2.name.value, '');
      expect(b3.name.value, '');
      expect(a2.name.value, '');
      expect(a3.name.value, '');
    });

    test('independent concurrent edits stay isolated per board', () async {
      a1.name.value = 'from-A-proj1';
      b2.name.value = 'from-B-proj2';
      a3.owner.name.value = 'Carol';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(b1.name.value, 'from-A-proj1');
      expect(a2.name.value, 'from-B-proj2');
      expect(b3.owner.name.value, 'Carol');

      // Untouched boards remain empty.
      expect(a1.owner.name.value, '');
      expect(b1.owner.name.value, '');
      expect(a2.owner.name.value, '');
      expect(b2.owner.name.value, '');
      expect(a3.name.value, '');
      expect(b3.name.value, '');
    });

    test('concurrent edits to the same board converge', () async {
      a1.name.value = 'name-A';
      b1.name.value = 'name-B';
      final ca = a1.cards.add();
      ca.title.value = 'card-A';
      final cb = b1.cards.add();
      cb.title.value = 'card-B';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(a1.name.value, b1.name.value);
      expect(a1.cards.length, 2);
      expect(b1.cards.length, 2);
      expect(
        a1.cards.map((c) => c.title.value).toList(),
        b1.cards.map((c) => c.title.value).toList(),
      );
      expect(
        a1.cards.map((c) => c.title.value).toSet(),
        {'card-A', 'card-B'},
      );

      // Other boards were not touched.
      expect(a2.cards.isEmpty, true);
      expect(b2.cards.isEmpty, true);
      expect(a3.cards.isEmpty, true);
      expect(b3.cards.isEmpty, true);
    });

    test('nested and node-list edits are scoped to one board', () async {
      a2.owner.name.value = 'Owner-2';
      final card = a2.cards.add();
      card.title.value = 'scoped';
      card.labels.add('red');
      card.labels.add('urgent');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(b2.owner.name.value, 'Owner-2');
      expect(b2.cards.length, 1);
      expect(b2.cards[0].title.value, 'scoped');
      expect(b2.cards[0].labels.toViewList(), ['red', 'urgent']);

      expect(b1.owner.name.value, '');
      expect(b1.cards.isEmpty, true);
      expect(b3.owner.name.value, '');
      expect(b3.cards.isEmpty, true);
    });

    test('unknown board id is lazily materialized on the peer', () async {
      final aNew = Board('clientA')..register();
      host.addDocument('clientA', 'proj-new', aNew);
      aNew.name.value = 'Discovered';
      aNew.owner.name.value = 'Discoverer';
      final card = aNew.cards.add();
      card.title.value = 'first card';

      await Future.delayed(const Duration(milliseconds: 10));

      final bNew = host.node('clientB')['proj-new'] as Board?;
      expect(bNew, isNotNull);
      expect(bNew!.name.value, 'Discovered');
      expect(bNew.owner.name.value, 'Discoverer');
      expect(bNew.cards.length, 1);
      expect(bNew.cards[0].title.value, 'first card');

      // Subsequent edits continue to flow both ways.
      bNew.owner.color.value = '#00ff00';
      await Future.delayed(const Duration(milliseconds: 10));
      expect(aNew.owner.color.value, '#00ff00');
    });

    test('each board keeps an independent clock domain', () async {
      expect(a1.lamportClock, 0);
      expect(a2.lamportClock, 0);

      a1.name.value = 'tick-1';
      a1.owner.name.value = 'tick-2';

      await Future.delayed(const Duration(milliseconds: 10));

      expect(a1.lamportClock, greaterThan(0));
      expect(b1.lamportClock, greaterThan(0));
      expect(a2.lamportClock, 0);
      expect(b2.lamportClock, 0);
      expect(a3.lamportClock, 0);
      expect(b3.lamportClock, 0);
    });

    test('interleaved edits across three boards converge', () async {
      a1.name.value = 'P1';
      b2.name.value = 'P2';
      a3.name.value = 'P3';
      await Future.delayed(Duration.zero);

      a1.owner.name.value = 'A1-owner';
      b2.owner.name.value = 'B2-owner';
      a3.owner.name.value = 'A3-owner';
      await Future.delayed(Duration.zero);

      final c1 = a1.cards.add()..title.value = 'c1';
      final c2 = b2.cards.add()..title.value = 'c2';
      final c3 = a3.cards.add()..title.value = 'c3';
      c1.labels.add('l1');
      c2.labels.add('l2');
      c3.labels.add('l3');

      await Future.delayed(const Duration(milliseconds: 20));

      expect(b1.name.value, 'P1');
      expect(a2.name.value, 'P2');
      expect(b3.name.value, 'P3');

      expect(b1.owner.name.value, 'A1-owner');
      expect(a2.owner.name.value, 'B2-owner');
      expect(b3.owner.name.value, 'A3-owner');

      expect(b1.cards.map((c) => c.title.value).toList(), ['c1']);
      expect(a2.cards.map((c) => c.title.value).toList(), ['c2']);
      expect(b3.cards.map((c) => c.title.value).toList(), ['c3']);

      expect(b1.cards[0].labels.toViewList(), ['l1']);
      expect(a2.cards[0].labels.toViewList(), ['l2']);
      expect(b3.cards[0].labels.toViewList(), ['l3']);

      expect(a1.name.value, b1.name.value);
      expect(a2.name.value, b2.name.value);
      expect(a3.name.value, b3.name.value);
    });
  });
}
