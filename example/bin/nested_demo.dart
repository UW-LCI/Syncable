// ignore_for_file: avoid_print

import 'package:syncable_properties/syncable_properties.dart';
import 'package:syncable_properties_example/models.dart';

/// Runs two in-memory replicas of a [Board] and mutates the nested structure on
/// one, showing the whole graph — nested child model and a list of `Card`
/// sub-models — converge on the other.
///
/// Run with: `dart run example/bin/nested_demo.dart`
void main() async {
  final host = SyncNodeHost();

  final boardA = Board('alice')..register();
  final boardB = Board('bob')..register();

  host.addNode('alice', boardA);
  host.addNode('bob', boardB);

  // Top-level + nested-child edits on A.
  boardA.name.value = 'Launch Plan';
  boardA.owner.name.value = 'Alice';
  boardA.owner.color.value = '#e91e63';

  // Create list elements (Card is itself a Syncable) and edit them.
  final design = boardA.cards.add();
  design.title.value = 'Design';
  design.labels.add('ui');
  design.labels.add('ux');

  final build = boardA.cards.add();
  build.title.value = 'Build';
  build.done.value = true;

  // A concurrent edit originating on B, to show bidirectional sync.
  await Future.delayed(const Duration(milliseconds: 10));
  boardB.cards[0].labels.add('priority');

  await Future.delayed(const Duration(milliseconds: 10));

  print('--- Board as seen by Bob ---');
  printBoard(boardB);

  print('\n--- Converged? ---');
  print('name:  ${boardA.name.value == boardB.name.value}');
  print('owner: ${boardA.owner.name.value == boardB.owner.name.value}');
  print('cards: ${_cardTitles(boardA)} == ${_cardTitles(boardB)} '
      '=> ${_cardTitles(boardA).toString() == _cardTitles(boardB).toString()}');

  host.close();

  await _typedListDemo();
}

/// Demonstrates a typed (heterogeneous) node list: elements of different
/// Syncable subtypes in one synced list.
Future<void> _typedListDemo() async {
  final host = SyncNodeHost();
  final feedA = Feed('alice')..register();
  final feedB = Feed('bob')..register();
  host.addNode('alice', feedA);
  host.addNode('bob', feedB);

  final note = feedA.items.add('note') as NoteItem;
  note.text.value = 'Remember the milk';
  final link = feedA.items.add('link') as LinkItem;
  link.url.value = 'https://dart.dev';
  link.caption.value = 'Dart';

  await Future.delayed(const Duration(milliseconds: 10));

  print('\n--- Feed as seen by Bob (mixed types) ---');
  for (final item in feedB.items) {
    if (item is NoteItem) {
      print('  note: ${item.text.value}');
    } else if (item is LinkItem) {
      print('  link: ${item.caption.value} -> ${item.url.value}');
    }
  }

  host.close();
}

void printBoard(Board board) {
  print('Board "${board.name.value}"  owner: ${board.owner.name.value} '
      '(${board.owner.color.value})');
  for (final card in board.cards) {
    final check = card.done.value ? 'x' : ' ';
    final labels = card.labels.toViewList().join(', ');
    print('  [$check] ${card.title.value}'
        '${labels.isEmpty ? '' : '  <$labels>'}');
  }
}

List<String> _cardTitles(Board board) =>
    board.cards.map((c) => c.title.value).toList();
