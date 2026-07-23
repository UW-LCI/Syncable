import 'package:test/test.dart';

import 'package:syncable_properties_example/models.dart';
import 'package:syncable_properties_example/sync_network.dart';

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
}
