# syncable

CRDT-based property sync for Dart and Flutter. Model local state as nested `Syncable` trees, exchange Lamport-timestamped changes over a transport, and optionally persist documents through a WebSocket relay.

## What it does

- **Syncable models** — Register values, lists, nested children, and homogeneous node lists on a `Syncable`. Each replica has a `nodeId`; concurrent updates resolve with last-writer-wins (Lamport clock + node id).
- **Nested documents** — Changes bubble to the root with a path, so deep trees stay consistent without flattening your domain model.
- **Dynamic documents** — `DynamicSyncable` materializes properties on demand from remote changes when you do not have a fixed schema.
- **Networking** — Serialize `SyncableChange` messages, bind a model (or many documents) to a `MessageTransport`, and sync over in-memory hubs or WebSockets.
- **Multi-document sync** — `DocumentSyncNode` multiplexes many root documents over one connection (tagged by `instanceId`) and supports catch-up from a persister.
- **Relay + persistence (VM / desktop)** — `WebSocketRelayServer` broadcasts client frames; `DocumentPersister` can snapshot documents to disk and serve catch-up.

Import the core API from `package:syncable/syncable.dart`. Relay and persister APIs use `dart:io` and live in `package:syncable/syncable_io.dart` — do not import that barrel from Flutter web builds.

## Getting started

Add the package to your `pubspec.yaml` (path or hosted dependency), then:

```dart
import 'package:syncable/syncable.dart';
```

Minimal local model:

```dart
final doc = Syncable('node-a');
final title = doc.syncableValue<String>('title', '');
title.value = 'Hello';
```

Wire a single document to a transport with `SyncNetwork`, or many documents with `DocumentSyncNode` + `WebSocketClientTransport`.

## Starting the relay server

The package ships a CLI entrypoint and a programmatic API.

### CLI (`bin/server.dart`)

From the package root:

```bash
dart run bin/server.dart
```

Default port is **8080**, host is **127.0.0.1**. The process listens for WebSocket clients at `ws://<host>:<port>/ws`.

#### Port and host

```bash
dart run bin/server.dart 9000
dart run bin/server.dart --host=0.0.0.0
dart run bin/server.dart 9000 --host=192.168.1.10
```

`--host` accepts an IP address. Use `0.0.0.0` (or a specific NIC IP) to accept connections from other machines. Clients must connect with a reachable host — not `0.0.0.0`.

#### With document persistence

Pass `--persist-dir` to attach a `DocumentPersister` that connects to the relay, loads snapshots from disk, and periodically flushes CRDT state:

```bash
dart run bin/server.dart --persist-dir=./data
```

Optional persistence flags (all require `--persist-dir`):

| Flag | Default | Meaning |
|------|---------|---------|
| `--persist-interval=<seconds>` | `60` | Flush interval |
| `--persist-keep-versions` | off | Keep historical snapshot files instead of deleting older ones |
| `--persist-as-of=<yyyyMMddTHHmmssZ>` | latest | Load the newest snapshot at or before this UTC stamp |

Examples:

```bash
# Custom port + persistence every 30s
dart run bin/server.dart 9000 --persist-dir=./data --persist-interval=30

# Retain versioned snapshots
dart run bin/server.dart --persist-dir=./data --persist-keep-versions

# Restore as of a point in time, then keep syncing
dart run bin/server.dart --persist-dir=./data --persist-as-of=20260724T180000Z
```

Usage on error:

```text
Usage: dart run bin/server.dart [port] [--host=<ip>]
  [--persist-dir=<path>] [--persist-interval=<seconds>]
  [--persist-keep-versions] [--persist-as-of=<yyyyMMddTHHmmssZ>]
```

### Programmatic API

For embedding the relay in your own process:

```dart
import 'dart:io';

import 'package:syncable/syncable_io.dart';

Future<void> main() async {
  final server = WebSocketRelayServer(
    address: InternetAddress.anyIPv4, // or a specific NIC IP
    port: 8080,
  );
  await server.start();
  print('Relay at ${server.wsUrl}');
}
```

`WebSocketRelayServer` defaults to loopback IPv4, port `5582`, path `/ws`. Pass `address` to bind another interface. Use `port: 0` for an ephemeral port, then read `boundPort` / `wsUrl`.

To add persistence yourself:

```dart
import 'dart:io';

import 'package:syncable/syncable_io.dart';

Future<void> main() async {
  final server = WebSocketRelayServer(port: 8080);
  await server.start();

  final persister = DocumentPersister(
    wsUrl: server.wsUrl,
    directory: Directory('./data'),
    interval: const Duration(seconds: 60),
  );
  await persister.start();
}
```

### Connecting a client

Clients import the main library (not the `_io` barrel):

```dart
import 'package:syncable/syncable.dart';

final transport = WebSocketClientTransport('node-a', 'ws://127.0.0.1:8080/ws');
await transport.connect();

final node = DocumentSyncNode(
  transport,
  factory: (nodeId, instanceId) => DynamicSyncable(nodeId),
);
```

The first outbound frame after connect is the client `nodeId` (handshake). Later frames are sync or control messages; the relay broadcasts to other peers, or delivers unicast wrappers to a named peer.

## Features at a glance

| Piece | Role |
|-------|------|
| `Syncable` / `SyncableValue` / `SyncableList` / `SyncableNodeList` | Local CRDT property graph |
| `DynamicSyncable` | Schema-free replica for persistence / unknown shapes |
| `SyncNetwork` / `SyncNodeHost` | Single-doc sync; in-memory multi-node host |
| `DocumentSyncNode` / `DocumentSyncHost` | Multi-doc sync + catch-up |
| `WebSocketClientTransport` | Client transport over WebSockets |
| `WebSocketRelayServer` | Simple broadcast / unicast relay (`dart:io`) |
| `DocumentPersister` | Disk snapshots + catch-up source (`dart:io`) |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
