import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncable/syncable.dart';
import 'package:syncable/syncable_io.dart';

class TestModel extends Syncable {
  TestModel(super.nodeId);

  late final SyncableValue<String> title = syncableValue('title', '');
  late final SyncableValue<int> counter = syncableValue('counter', 0);
  late final SyncableList<String> items = syncableList('items');

  void warmUp() {
    title;
    counter;
    items;
  }
}

class _WsPeer {
  _WsPeer(this.transport, this.network, this.model);

  final WebSocketClientTransport transport;
  final SyncNetwork network;
  final TestModel model;

  void close() => network.close();
}

class _WsDocPeer {
  _WsDocPeer(this.transport, this.node);

  final WebSocketClientTransport transport;
  final DocumentSyncNode node;

  void close() => node.close();
}

Future<_WsPeer> _connectPeer(String nodeId, String wsUrl) async {
  final transport = WebSocketClientTransport(nodeId, wsUrl);
  await transport.connect();
  final model = TestModel(nodeId)..warmUp();
  final network = SyncNetwork(transport, model);
  // Let the handshake settle before tests mutate.
  await Future.delayed(const Duration(milliseconds: 20));
  return _WsPeer(transport, network, model);
}

Future<_WsDocPeer> _connectDocPeer(
  String nodeId,
  String wsUrl, {
  DocumentFactory? factory,
}) async {
  final transport = WebSocketClientTransport(nodeId, wsUrl);
  await transport.connect();
  final node = DocumentSyncNode(
    transport,
    factory: factory,
    autoCatchUp: false,
  );
  await Future.delayed(const Duration(milliseconds: 20));
  return _WsDocPeer(transport, node);
}

void main() {
  group('WebSocket SyncNetwork', () {
    late WebSocketRelayServer server;
    late _WsPeer peerA;
    late _WsPeer peerB;

    setUp(() async {
      server = WebSocketRelayServer(port: 0);
      await server.start();
      peerA = await _connectPeer('clientA', server.wsUrl);
      peerB = await _connectPeer('clientB', server.wsUrl);
    });

    tearDown(() async {
      peerA.close();
      peerB.close();
      await server.close();
    });

    test('value edit on A appears on B', () async {
      peerA.model.title.value = 'Hello over WS';

      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerB.model.title.value, 'Hello over WS');
    });

    test('value edit on B appears on A', () async {
      peerB.model.counter.value = 42;

      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerA.model.counter.value, 42);
    });

    test('list insert remove and update converge', () async {
      peerA.model.items.add('keep');
      await Future.delayed(const Duration(milliseconds: 30));
      peerA.model.items.add('drop');
      await Future.delayed(const Duration(milliseconds: 30));
      peerA.model.items.removeAt(1);
      await Future.delayed(const Duration(milliseconds: 30));
      peerA.model.items[0] = 'kept';

      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerB.model.items.toViewList(), ['kept']);
      expect(peerA.model.items.toViewList(), peerB.model.items.toViewList());
    });

    test('malformed frames are ignored', () async {
      peerA.transport.send('not-json');
      peerA.transport.send('{]');
      peerA.model.title.value = 'after-garbage';

      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerB.model.title.value, 'after-garbage');
    });
  });

  group('WebSocket bind address', () {
    test('anyIPv4 accepts clients via 127.0.0.1', () async {
      final server = WebSocketRelayServer(
        address: InternetAddress.anyIPv4,
        port: 0,
      );
      await server.start();
      final wsUrl = 'ws://127.0.0.1:${server.boundPort}${server.path}';

      final peerA = await _connectPeer('clientA', wsUrl);
      final peerB = await _connectPeer('clientB', wsUrl);

      peerA.model.title.value = 'lan-ok';
      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerB.model.title.value, 'lan-ok');

      peerA.close();
      peerB.close();
      await server.close();
    });
  });

  group('WebSocket late joiner and disconnect', () {
    test('late joiner receives subsequent edits only', () async {
      final server = WebSocketRelayServer(port: 0);
      await server.start();
      final peerA = await _connectPeer('clientA', server.wsUrl);
      final peerB = await _connectPeer('clientB', server.wsUrl);

      peerA.model.title.value = 'established';
      peerA.model.items.add('item1');
      await Future.delayed(const Duration(milliseconds: 50));

      final peerC = await _connectPeer('clientC', server.wsUrl);
      peerA.model.items.add('item2');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerB.model.items.toViewList(), contains('item2'));
      expect(peerC.model.items.toViewList(), contains('item2'));
      // SyncNetwork has no persister catch-up — late joiner only gets live traffic.
      // DocumentPersister + requestCatchUp covers historical CRDT snapshots.
      expect(peerC.model.title.value, '');

      peerA.close();
      peerB.close();
      peerC.close();
      await server.close();
    });

    test('remaining peers sync after one disconnects', () async {
      final server = WebSocketRelayServer(port: 0);
      await server.start();
      final peerA = await _connectPeer('clientA', server.wsUrl);
      final peerB = await _connectPeer('clientB', server.wsUrl);
      final peerC = await _connectPeer('clientC', server.wsUrl);

      peerA.close();
      await Future.delayed(const Duration(milliseconds: 30));

      peerB.model.title.value = 'still-alive';
      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerC.model.title.value, 'still-alive');

      final peerA2 = await _connectPeer('clientA', server.wsUrl);
      peerC.model.counter.value = 7;
      await Future.delayed(const Duration(milliseconds: 50));

      expect(peerA2.model.counter.value, 7);
      expect(peerB.model.counter.value, 7);

      peerA2.close();
      peerB.close();
      peerC.close();
      await server.close();
    });
  });

  group('WebSocket DocumentSyncNode', () {
    test('routes edits by instance id across the wire', () async {
      final server = WebSocketRelayServer(port: 0);
      await server.start();

      final peerA = await _connectDocPeer('clientA', server.wsUrl);
      final peerB = await _connectDocPeer(
        'clientB',
        server.wsUrl,
        factory: (nodeId, _) => TestModel(nodeId)..warmUp(),
      );

      final a1 = TestModel('clientA')..warmUp();
      final a2 = TestModel('clientA')..warmUp();
      final b1 = TestModel('clientB')..warmUp();
      final b2 = TestModel('clientB')..warmUp();

      peerA.node.register('doc1', a1);
      peerA.node.register('doc2', a2);
      peerB.node.register('doc1', b1);
      peerB.node.register('doc2', b2);

      a1.title.value = 'only-doc1';
      await Future.delayed(const Duration(milliseconds: 50));

      expect(b1.title.value, 'only-doc1');
      expect(b2.title.value, '');
      expect(a2.title.value, '');

      a2.items.add('doc2-item');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(b2.items.toViewList(), ['doc2-item']);
      expect(b1.items.isEmpty, true);

      peerA.close();
      peerB.close();
      await server.close();
    });
  });

  group('WebSocket unicast routing', () {
    test('sendTo delivers to one client only', () async {
      final server = WebSocketRelayServer(port: 0);
      await server.start();

      final a = WebSocketClientTransport('a', server.wsUrl);
      final b = WebSocketClientTransport('b', server.wsUrl);
      final c = WebSocketClientTransport('c', server.wsUrl);
      await a.connect();
      await b.connect();
      await c.connect();
      await Future.delayed(const Duration(milliseconds: 20));

      final receivedB = <String>[];
      final receivedC = <String>[];
      b.onMessage.listen(receivedB.add);
      c.onMessage.listen(receivedC.add);

      a.sendTo('b', '{"hello":"b"}');
      a.send('{"hello":"all"}');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(receivedB, contains('{"hello":"b"}'));
      expect(receivedB, contains('{"hello":"all"}'));
      expect(receivedC, isNot(contains('{"hello":"b"}')));
      expect(receivedC, contains('{"hello":"all"}'));

      a.close();
      b.close();
      c.close();
      await server.close();
    });
  });
}
