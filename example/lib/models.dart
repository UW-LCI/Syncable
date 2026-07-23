import 'package:syncable_properties/syncable_properties.dart';

/// A collaborative Kanban-style board demonstrating the composite features of
/// `syncable_properties`:
///
/// * [Board.owner] is a **nested Syncable** ([Author]).
/// * [Board.cards] is a **list of Syncable subclasses** ([SyncableNodeList] of
///   [Card]), each element being its own syncing model.
/// * [Card.labels] shows a primitive [SyncableList] nested inside a list
///   element.
///
/// Every mutation anywhere in this tree flows through the board's single stream
/// and clock, so wiring one [Board] to a [SyncNetwork] syncs the whole graph.
class Author extends Syncable {
  Author(super.nodeId);

  late final SyncableValue<String> name = syncableValue('name', '');
  late final SyncableValue<String> color = syncableValue('color', '#888888');
}

class Card extends Syncable {
  Card(super.nodeId);

  late final SyncableValue<String> title = syncableValue('title', '');
  late final SyncableValue<bool> done = syncableValue('done', false);
  late final SyncableList<String> labels = syncableList('labels');
}

class Board extends Syncable {
  Board(super.nodeId);

  late final SyncableValue<String> name = syncableValue('name', '');
  late final Author owner = syncableChild('owner', Author(nodeId));
  late final SyncableNodeList<Card> cards =
      syncableNodeList('cards', () => Card(nodeId));

  /// Touches every property so the whole tree is registered eagerly. Useful for
  /// a freshly-created replica that should apply incoming remote changes
  /// immediately rather than buffering them until first access.
  void register() {
    name;
    owner.name;
    owner.color;
    cards;
  }
}

/// A feed whose entries can be *different* Syncable subtypes, demonstrating a
/// typed [SyncableNodeList]. Elements are created with a `typeId`
/// (`feed.items.add('note')`), which travels with the insert so peers rebuild
/// the matching subtype.
class NoteItem extends Syncable {
  NoteItem(super.nodeId);

  late final SyncableValue<String> text = syncableValue('text', '');
}

class LinkItem extends Syncable {
  LinkItem(super.nodeId);

  late final SyncableValue<String> url = syncableValue('url', '');
  late final SyncableValue<String> caption = syncableValue('caption', '');
}

class Feed extends Syncable {
  Feed(super.nodeId);

  late final SyncableNodeList<Syncable> items = syncableTypedNodeList('items', {
    'note': () => NoteItem(nodeId),
    'link': () => LinkItem(nodeId),
  });

  void register() {
    items;
  }
}
