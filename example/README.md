# syncable_properties_example

Domain models and demos that show how to build nested, composite syncable documents on top of `syncable_properties`. Networking and transport live in the parent package; this package only defines example models and exercises them in-process.

## What it demonstrates

- **Nested Syncables** — A `Board` owns an `Author` child (`syncableChild`).
- **Lists of Syncables** — `Board.cards` is a `SyncableNodeList` of `Card` elements; each card has its own values and a primitive `labels` list.
- **Typed (heterogeneous) node lists** — A `Feed` holds mixed `NoteItem` / `LinkItem` subtypes via `syncableTypedNodeList`.
- **Multi-document sync** — Tests multiplex several root boards over one in-memory host (`DocumentSyncHost`).

Every mutation in a model tree shares the root’s clock and change stream, so wiring one root to a transport syncs the whole graph.

## Layout

```text
example/
├── lib/
│   └── models.dart          # Board, Card, Author, Feed, NoteItem, LinkItem
├── bin/
│   └── nested_demo.dart     # Printable two-replica demo
├── test/
│   └── composite_sync_test.dart
└── pubspec.yaml             # Depends on syncable_properties via path: ..
```

| Path | Role |
|------|------|
| `lib/models.dart` | Typed domain models extending `Syncable` |
| `bin/nested_demo.dart` | CLI demo: two in-memory replicas of a board (then a feed) converge |
| `test/composite_sync_test.dart` | Unit tests for nested sync, typed lists, and multi-board isolation |

## Models

Defined in `lib/models.dart`:

- **`Author`** — `name`, `color`
- **`Card`** — `title`, `done`, `labels` (`SyncableList<String>`)
- **`Board`** — `name`, nested `owner` (`Author`), `cards` (`SyncableNodeList<Card>`)
- **`NoteItem` / `LinkItem` / `Feed`** — Heterogeneous feed entries keyed by type id (`note`, `link`)

Call `register()` on a freshly created `Board` or `Feed` so the whole tree is registered before remote changes arrive.

## Running

From the **repository root**:

```bash
# Interactive demo (board + typed feed)
dart run example/bin/nested_demo.dart
```

From the **example** directory:

```bash
dart test
```

Or from the repo root:

```bash
dart test example
```

The demo and tests use `SyncNodeHost` / `DocumentSyncHost` (in-memory transports). They do not start a WebSocket server.
