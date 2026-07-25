import 'package:flutter_test/flutter_test.dart';

import 'package:syncable/syncable.dart';

class Profile extends Syncable {
  Profile(super.nodeId);

  late final SyncableValue<String> name = syncableValue('name', '');
  late final SyncableValue<int> age = syncableValue('age', 0);
  late final SyncableList<String> tags = syncableList('tags');
}

class Settings extends Syncable {
  Settings(super.nodeId);

  late final SyncableValue<bool> darkMode = syncableValue('darkMode', false);
  late final Profile owner = syncableChild('owner', Profile(nodeId));
}

class Todo extends Syncable {
  Todo(super.nodeId);

  late final SyncableValue<String> text = syncableValue('text', '');
  late final SyncableValue<bool> done = syncableValue('done', false);
}

class AppModel extends Syncable {
  AppModel(super.nodeId);

  late final SyncableValue<int> count = syncableValue('count', 0);
  late final Profile profile = syncableChild('profile', Profile(nodeId));
  late final Settings settings = syncableChild('settings', Settings(nodeId));
  late final SyncableNodeList<Todo> todos =
      syncableNodeList('todos', () => Todo(nodeId));
}

class TextNote extends Syncable {
  TextNote(super.nodeId);

  late final SyncableValue<String> body = syncableValue('body', '');
}

class Reminder extends Syncable {
  Reminder(super.nodeId);

  late final SyncableValue<String> label = syncableValue('label', '');
  late final SyncableValue<int> at = syncableValue('at', 0);
}

class Feed extends Syncable {
  Feed(super.nodeId);

  late final SyncableNodeList<Syncable> items = syncableTypedNodeList('items', {
    'note': () => TextNote(nodeId),
    'reminder': () => Reminder(nodeId),
  });
}

/// Wires two models so that every change on [a] is applied to [b] and vice
/// versa, mimicking a synchronous transport.
void link(Syncable a, Syncable b) {
  a.onPropertyChange.listen((c) {
    if (c.nodeId != b.nodeId) b.applyRemoteChange(c);
  });
  b.onPropertyChange.listen((c) {
    if (c.nodeId != a.nodeId) a.applyRemoteChange(c);
  });
}

void main() {
  group('Standalone still works', () {
    test('a nested-capable class used on its own behaves like before', () {
      final profile = Profile('device1');
      expect(profile.name.value, '');
      profile.name.value = 'Alice';
      expect(profile.name.value, 'Alice');
      expect(profile.lamportClock, 1);
      profile.tags.add('a');
      expect(profile.tags.toViewList(), ['a']);
    });

    test('standalone changes carry an empty path', () {
      final profile = Profile('device1');
      SyncableChange? seen;
      profile.onPropertyChange.listen((c) => seen = c);
      profile.name.value = 'x';
      expect(seen, isA<ValueSetChange>());
      expect(seen!.path, isEmpty);
      expect(seen!.propertyKey, 'name');
    });
  });

  group('Nested value sync', () {
    test('nested set updates the child value', () {
      final app = AppModel('device1');
      app.profile.name.value = 'Bob';
      expect(app.profile.name.value, 'Bob');
    });

    test('nested change bubbles to root stream with a path prefix', () {
      final app = AppModel('device1');
      SyncableChange? seen;
      app.onPropertyChange.listen((c) => seen = c);

      app.profile.name.value = 'Bob';

      expect(seen, isA<ValueSetChange>());
      expect(seen!.propertyKey, 'name');
      expect(seen!.path, ['profile']);
    });

    test('nested value syncs between two models', () {
      final a = AppModel('A');
      final b = AppModel('B');
      // Register children on both sides.
      a.profile.name;
      b.profile.name;
      link(a, b);

      a.profile.name.value = 'from A';

      expect(b.profile.name.value, 'from A');
    });

    test('top-level and nested edits stay isolated', () {
      final a = AppModel('A');
      final b = AppModel('B');
      a.count;
      a.profile.name;
      b.count;
      b.profile.name;
      link(a, b);

      a.count.value = 7;
      a.profile.name.value = 'deep';

      expect(b.count.value, 7);
      expect(b.profile.name.value, 'deep');
    });
  });

  group('Shared clock domain', () {
    test('nested edits advance the single root clock', () {
      final app = AppModel('device1');
      expect(app.lamportClock, 0);

      app.count.value = 1;
      expect(app.lamportClock, 1);

      app.profile.name.value = 'x';
      expect(app.lamportClock, 2);

      app.settings.owner.name.value = 'deep';
      expect(app.lamportClock, 3);
    });

    test('child reports the root clock', () {
      final app = AppModel('device1');
      app.count.value = 5;
      expect(app.profile.lamportClock, app.lamportClock);
    });
  });

  group('Deep nesting', () {
    test('two-level nested value syncs with a two-segment path', () {
      final a = AppModel('A');
      final b = AppModel('B');
      SyncableChange? seen;
      a.onPropertyChange.listen((c) => seen = c);
      a.settings.owner.name;
      b.settings.owner.name;
      link(a, b);

      a.settings.owner.name.value = 'grandchild';

      expect(seen!.path, ['settings', 'owner']);
      expect(seen!.propertyKey, 'name');
      expect(b.settings.owner.name.value, 'grandchild');
    });
  });

  group('Nested list sync', () {
    test('a list inside a child model syncs', () {
      final a = AppModel('A');
      final b = AppModel('B');
      a.profile.tags;
      b.profile.tags;
      link(a, b);

      a.profile.tags.add('red');
      a.profile.tags.add('blue');

      expect(b.profile.tags.toViewList(), ['red', 'blue']);
    });
  });

  group('Pending replay for late-registered children', () {
    test('remote change applied before child access replays on registration',
        () {
      final b = AppModel('B');

      // Apply a nested change before b.profile (or b.profile.name) has ever
      // been touched, so neither the child nor the leaf is registered yet.
      b.applyRemoteChange(
        ValueSetChange<String>(
          propertyKey: 'name',
          nodeId: 'A',
          lamportClock: 5,
          value: 'buffered',
          path: const ['profile'],
        ),
      );

      expect(b.profile.name.value, 'buffered');
    });
  });

  group('Transition standalone -> nested', () {
    test('attaching a mutated standalone child absorbs its clock', () {
      final container = _Container('A');
      final profile = Profile('A');
      profile.name.value = 'pre'; // clock 1 while standalone
      expect(profile.lamportClock, 1);

      final attached = container.attach(profile);
      expect(container.lamportClock, 1); // absorbed, no artificial bump

      attached.name.value = 'post'; // now ticks the container's clock
      expect(container.lamportClock, 2);
      expect(profile.lamportClock, 2); // child delegates to the new root
    });
  });

  group('SyncableNodeList', () {
    test('add returns a configurable child and length tracks it', () {
      final app = AppModel('device1');
      final t = app.todos.add();
      t.text.value = 'buy milk';

      expect(app.todos.length, 1);
      expect(app.todos[0].text.value, 'buy milk');
    });

    test('element creation and its edits sync to a peer', () {
      final a = AppModel('A');
      final b = AppModel('B');
      a.todos;
      b.todos;
      link(a, b);

      final t = a.todos.add();
      t.text.value = 'walk dog';
      t.done.value = true;

      expect(b.todos.length, 1);
      expect(b.todos[0].text.value, 'walk dog');
      expect(b.todos[0].done.value, true);
    });

    test('removal syncs to a peer', () {
      final a = AppModel('A');
      final b = AppModel('B');
      a.todos;
      b.todos;
      link(a, b);

      final t0 = a.todos.add();
      t0.text.value = 'keep';
      final t1 = a.todos.add();
      t1.text.value = 'remove';

      expect(b.todos.length, 2);

      a.todos.removeAt(1);

      expect(a.todos.length, 1);
      expect(b.todos.length, 1);
      expect(b.todos[0].text.value, 'keep');
    });

    test('later edits to a synced element propagate', () {
      final a = AppModel('A');
      final b = AppModel('B');
      a.todos;
      b.todos;
      link(a, b);

      final t = a.todos.add();
      t.text.value = 'v1';
      expect(b.todos[0].text.value, 'v1');

      // Edit the same element again; and edit it from B's side too.
      t.text.value = 'v2';
      expect(b.todos[0].text.value, 'v2');

      b.todos[0].done.value = true;
      expect(a.todos[0].done.value, true);
    });

    test('concurrent element inserts converge', () {
      final a = AppModel('A');
      final b = AppModel('B');
      a.todos;
      b.todos;
      link(a, b);

      final ta = a.todos.add();
      ta.text.value = 'fromA';
      final tb = b.todos.add();
      tb.text.value = 'fromB';

      expect(a.todos.length, 2);
      expect(b.todos.length, 2);
      expect(
        a.todos.map((t) => t.text.value).toList(),
        b.todos.map((t) => t.text.value).toList(),
      );
      expect(
        a.todos.map((t) => t.text.value).toSet(),
        {'fromA', 'fromB'},
      );
    });
  });

  group('Typed (heterogeneous) node list', () {
    test('add constructs the requested subtype', () {
      final feed = Feed('device1');
      final note = feed.items.add('note');
      final rem = feed.items.add('reminder');

      expect(note, isA<TextNote>());
      expect(rem, isA<Reminder>());
      expect(feed.items.length, 2);
    });

    test('peer rebuilds the correct subtypes with their edits', () {
      final a = Feed('A');
      final b = Feed('B');
      a.items;
      b.items;
      link(a, b);

      final note = a.items.add('note') as TextNote;
      note.body.value = 'hello';
      final rem = a.items.add('reminder') as Reminder;
      rem.label.value = 'standup';
      rem.at.value = 900;

      expect(b.items.length, 2);
      expect(b.items[0], isA<TextNote>());
      expect((b.items[0] as TextNote).body.value, 'hello');
      expect(b.items[1], isA<Reminder>());
      expect((b.items[1] as Reminder).label.value, 'standup');
      expect((b.items[1] as Reminder).at.value, 900);
    });

    test('misuse throws: homogeneous rejects id, typed requires known id', () {
      final app = AppModel('device1');
      expect(() => app.todos.add('nope'), throwsStateError);

      final feed = Feed('device1');
      expect(() => feed.items.add(), throwsStateError);
      expect(() => feed.items.add('unknown'), throwsStateError);
    });
  });
}

class _Container extends Syncable {
  _Container(super.nodeId);

  Profile attach(Profile p) => syncableChild('profile', p);
}
