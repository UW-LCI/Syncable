import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncable/syncable.dart';
import 'package:syncable/syncable_io.dart';

class _Doc extends Syncable {
  _Doc(super.nodeId);

  late final SyncableValue<String> title = syncableValue('title', '');
  late final SyncableList<String> tags = syncableList('tags');

  void warmUp() {
    title;
    tags;
  }
}

List<File> _filesFor(Directory dir, String instanceId) {
  final pattern = RegExp('^${RegExp.escape(instanceId)}-\\d{8}T\\d{6}Z\\.json\$');
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => pattern.hasMatch(f.uri.pathSegments.last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Object? _crdtValue(Map<String, dynamic> json, String key) {
  expect(json['format'], 'syncable_crdt_v1');
  final props = json['properties'] as Map<String, dynamic>;
  final prop = props[key] as Map<String, dynamic>?;
  return prop?['value'];
}

List<Object?> _crdtListValues(Map<String, dynamic> json, String key) {
  expect(json['format'], 'syncable_crdt_v1');
  final props = json['properties'] as Map<String, dynamic>;
  final prop = props[key] as Map<String, dynamic>?;
  if (prop == null) return const [];
  final entries = prop['entries'] as List? ?? const [];
  return [
    for (final e in entries)
      if (e is Map && e['tombstone'] != true) e['value'],
  ];
}

Map<String, Object?> _minimalCrdtDoc({
  required String title,
  List<String> tags = const [],
}) {
  return {
    'format': 'syncable_crdt_v1',
    'lamportClock': tags.length + 1,
    'properties': {
      'title': {
        'kind': 'value',
        'value': title,
        'timestamp': 1,
        'writerNodeId': 'disk',
      },
      'tags': {
        'kind': 'list',
        'idCounter': tags.length,
        'entries': [
          for (var i = 0; i < tags.length; i++)
            {
              'id': 'disk:$i',
              'position': (i + 1) / (tags.length + 1),
              'tombstone': false,
              'value': tags[i],
            },
        ],
      },
    },
  };
}

void main() {
  group('DocumentPersister', () {
    late Directory tempDir;
    late WebSocketRelayServer server;
    late WebSocketClientTransport peerTransport;
    late DocumentSyncNode peerNode;
    late DocumentPersister persister;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('doc-persister-');
      server = WebSocketRelayServer(port: 0);
      await server.start();

      peerTransport = WebSocketClientTransport('peer', server.wsUrl);
      await peerTransport.connect();
      peerNode = DocumentSyncNode(peerTransport, autoCatchUp: false);

      persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(milliseconds: 100),
        nodeId: 'persister',
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    tearDown(() async {
      await persister.close();
      peerNode.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('writes one timestamped CRDT JSON file per document instance', () async {
      final docA = _Doc('peer')..warmUp();
      final docB = _Doc('peer')..warmUp();
      peerNode.register('alpha', docA);
      peerNode.register('beta', docB);

      docA.title.value = 'Alpha title';
      docA.tags.add('one');
      docB.title.value = 'Beta title';

      await Future<void>.delayed(const Duration(milliseconds: 50));
      persister.flush();

      final alphaFiles = _filesFor(tempDir, 'alpha');
      final betaFiles = _filesFor(tempDir, 'beta');
      expect(alphaFiles, hasLength(1));
      expect(betaFiles, hasLength(1));

      final alphaJson =
          jsonDecode(await alphaFiles.single.readAsString()) as Map<String, dynamic>;
      final betaJson =
          jsonDecode(await betaFiles.single.readAsString()) as Map<String, dynamic>;

      expect(_crdtValue(alphaJson, 'title'), 'Alpha title');
      expect(_crdtListValues(alphaJson, 'tags'), ['one']);
      expect(_crdtValue(betaJson, 'title'), 'Beta title');
      // Untouched properties are not materialized on DynamicSyncable.
      expect(
        (betaJson['properties'] as Map).containsKey('tags'),
        isFalse,
      );
    });

    test('periodic timer flushes without an explicit call', () async {
      final doc = _Doc('peer')..warmUp();
      peerNode.register('timed', doc);
      doc.title.value = 'from-timer';

      await Future<void>.delayed(const Duration(milliseconds: 250));

      final files = _filesFor(tempDir, 'timed');
      expect(files, hasLength(1));
      final json =
          jsonDecode(await files.single.readAsString()) as Map<String, dynamic>;
      expect(_crdtValue(json, 'title'), 'from-timer');
    });

    test('prunes older copies of a document by default', () async {
      final doc = _Doc('peer')..warmUp();
      peerNode.register('alpha', doc);
      doc.title.value = 'v1';
      await Future<void>.delayed(const Duration(milliseconds: 50));
      persister.flush();
      expect(_filesFor(tempDir, 'alpha'), hasLength(1));

      // Ensure a distinct timestamp so the second write is a new file.
      await Future<void>.delayed(const Duration(seconds: 1));
      doc.title.value = 'v2';
      await Future<void>.delayed(const Duration(milliseconds: 50));
      persister.flush();

      final files = _filesFor(tempDir, 'alpha');
      expect(files, hasLength(1));
      final json =
          jsonDecode(await files.single.readAsString()) as Map<String, dynamic>;
      expect(_crdtValue(json, 'title'), 'v2');
    });
  });

  group('DocumentPersister keepVersions', () {
    late Directory tempDir;
    late WebSocketRelayServer server;
    late WebSocketClientTransport peerTransport;
    late DocumentSyncNode peerNode;
    late DocumentPersister persister;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('doc-persister-keep-');
      server = WebSocketRelayServer(port: 0);
      await server.start();

      peerTransport = WebSocketClientTransport('peer', server.wsUrl);
      await peerTransport.connect();
      peerNode = DocumentSyncNode(peerTransport, autoCatchUp: false);

      persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
        keepVersions: true,
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    tearDown(() async {
      await persister.close();
      peerNode.close();
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('retains historical timestamped copies when keepVersions is set', () async {
      final doc = _Doc('peer')..warmUp();
      peerNode.register('alpha', doc);
      doc.title.value = 'v1';
      await Future<void>.delayed(const Duration(milliseconds: 50));
      persister.flush();

      await Future<void>.delayed(const Duration(seconds: 1));
      doc.title.value = 'v2';
      await Future<void>.delayed(const Duration(milliseconds: 50));
      persister.flush();

      final files = _filesFor(tempDir, 'alpha');
      expect(files, hasLength(2));
      final titles = [
        for (final f in files)
          _crdtValue(
            jsonDecode(await f.readAsString()) as Map<String, dynamic>,
            'title',
          ),
      ];
      expect(titles, containsAll(['v1', 'v2']));
    });
  });

  group('DocumentPersister file selection', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('doc-persister-select-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json')
          .writeAsString('{"title":"old"}');
      await File('${tempDir.path}/alpha-20260102T000000Z.json')
          .writeAsString('{"title":"mid"}');
      await File('${tempDir.path}/alpha-20260103T000000Z.json')
          .writeAsString('{"title":"new"}');
      await File('${tempDir.path}/beta-20260102T000000Z.json')
          .writeAsString('{"title":"beta"}');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('selectFilesToLoad picks the latest stamp per document', () {
      final persister = DocumentPersister(
        wsUrl: 'ws://127.0.0.1:0/ws',
        directory: tempDir,
      );
      final selected = persister.selectFilesToLoad();
      expect(selected.keys.toSet(), {'alpha', 'beta'});
      expect(
        selected['alpha']!.uri.pathSegments.last,
        'alpha-20260103T000000Z.json',
      );
      expect(
        selected['beta']!.uri.pathSegments.last,
        'beta-20260102T000000Z.json',
      );
    });

    test('selectFilesToLoad respects asOf upper bound', () {
      final persister = DocumentPersister(
        wsUrl: 'ws://127.0.0.1:0/ws',
        directory: tempDir,
      );
      final selected = persister.selectFilesToLoad(
        asOf: DocumentPersister.parseUtcStamp('20260102T120000Z'),
      );
      expect(
        selected['alpha']!.uri.pathSegments.last,
        'alpha-20260102T000000Z.json',
      );
      expect(selected.containsKey('beta'), isTrue);
    });
  });

  group('DocumentPersister reconstitution', () {
    late Directory tempDir;
    late WebSocketRelayServer server;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('doc-persister-load-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          _minimalCrdtDoc(title: 'old', tags: ['a']),
        ),
      );
      await File('${tempDir.path}/alpha-20260103T000000Z.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          _minimalCrdtDoc(title: 'latest', tags: ['b', 'c']),
        ),
      );
      server = WebSocketRelayServer(port: 0);
      await server.start();
    });

    tearDown(() async {
      await server.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('loads latest CRDT snapshots and broadcasts to a connected peer', () async {
      final peerTransport = WebSocketClientTransport('peer', server.wsUrl);
      await peerTransport.connect();
      final peerNode = DocumentSyncNode(
        peerTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
      );

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      expect(persister.documentsLoaded, 1);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      final doc = peerNode['alpha'];
      expect(doc, isNotNull);
      expect(doc!.toJson(), {
        'title': 'latest',
        'tags': ['b', 'c'],
      });
      // Element ids from disk are preserved (not reminted).
      expect(doc.toCrdtJson()['properties'], isA<Map>());
      final tags =
          (doc.toCrdtJson()['properties'] as Map)['tags'] as Map<String, dynamic>;
      expect((tags['entries'] as List).first['id'], 'disk:0');

      await persister.close();
      peerNode.close();
    });

    test('asOf reconstitutes the latest snapshot at or before the stamp', () async {
      final peerTransport = WebSocketClientTransport('peer', server.wsUrl);
      await peerTransport.connect();
      final peerNode = DocumentSyncNode(
        peerTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
      );

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
        asOf: DocumentPersister.parseUtcStamp('20260102T000000Z'),
      );
      await persister.start();
      expect(persister.documentsLoaded, 1);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      final doc = peerNode['alpha'];
      expect(doc, isNotNull);
      expect(doc!.toJson(), {
        'title': 'old',
        'tags': ['a'],
      });

      await persister.close();
      peerNode.close();
    });

    test('legacy value-only snapshots still load', () async {
      final legacyDir =
          await Directory.systemTemp.createTemp('doc-persister-legacy-');
      addTearDown(() async {
        if (await legacyDir.exists()) {
          await legacyDir.delete(recursive: true);
        }
      });
      await File('${legacyDir.path}/alpha-20260101T000000Z.json').writeAsString(
        jsonEncode({
          'title': 'legacy',
          'tags': ['x'],
        }),
      );

      final peerTransport = WebSocketClientTransport('peer', server.wsUrl);
      await peerTransport.connect();
      final peerNode = DocumentSyncNode(
        peerTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
      );

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: legacyDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      expect(persister.documentsLoaded, 1);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(peerNode['alpha']!.toJson(), {
        'title': 'legacy',
        'tags': ['x'],
      });

      persister.flush();
      final files = _filesFor(legacyDir, 'alpha');
      expect(files, isNotEmpty);
      final flushed =
          jsonDecode(await files.last.readAsString()) as Map<String, dynamic>;
      expect(flushed['format'], 'syncable_crdt_v1');

      await persister.close();
      peerNode.close();
    });
  });

  group('DocumentPersister catch-up', () {
    test('late joiner receives unicast CRDT snapshot; other peers do not', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('doc-persister-catchup-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          _minimalCrdtDoc(title: 'persisted', tags: ['a', 'b']),
        ),
      );

      final server = WebSocketRelayServer(port: 0);
      await server.start();
      addTearDown(() async {
        await server.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final earlyTransport = WebSocketClientTransport('early', server.wsUrl);
      await earlyTransport.connect();
      final earlyNode = DocumentSyncNode(
        earlyTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
      );
      final earlySnapshots = <String>[];
      earlyTransport.onMessage.listen((m) {
        try {
          final json = jsonDecode(m) as Map<String, dynamic>;
          if (json['type'] == catchupSnapshotType) {
            earlySnapshots.add(m);
          }
        } catch (_) {}
      });

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(earlyNode['alpha']!.toJson()['title'], 'persisted');
      final snapshotsAfterLoad = earlySnapshots.length;

      final lateTransport = WebSocketClientTransport('late', server.wsUrl);
      await lateTransport.connect();
      // Default autoCatchUp: true — no explicit requestCatchUp needed.
      final lateNode = DocumentSyncNode(
        lateTransport,
        factory: (id, _) => DynamicSyncable(id),
      );
      await lateNode.catchUp;

      expect(lateNode['alpha'], isNotNull);
      expect(lateNode['alpha']!.toJson(), {
        'title': 'persisted',
        'tags': ['a', 'b'],
      });
      final tags =
          (lateNode['alpha']!.toCrdtJson()['properties'] as Map)['tags'] as Map;
      expect((tags['entries'] as List).first['id'], 'disk:0');

      // Unicast catch-up must not deliver another snapshot to the early peer.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(earlySnapshots.length, snapshotsAfterLoad);

      await persister.close();
      earlyNode.close();
      lateNode.close();
    });

    test('client can prefer value snapshot catch-up over CRDT', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('doc-persister-snap-method-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json').writeAsString(
        jsonEncode(_minimalCrdtDoc(title: 'persisted', tags: ['a', 'b'])),
      );

      final server = WebSocketRelayServer(port: 0);
      await server.start();
      addTearDown(() async {
        await server.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      CatchUpMethod? seenMethod;
      final lateTransport = WebSocketClientTransport('late', server.wsUrl);
      await lateTransport.connect();
      lateTransport.onMessage.listen((m) {
        try {
          final json = jsonDecode(m) as Map<String, dynamic>;
          if (json['type'] == catchupSnapshotType) {
            seenMethod = CatchUpMethod.parse(json['method'] as String?);
          }
        } catch (_) {}
      });

      final lateNode = DocumentSyncNode(
        lateTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
        catchUpMethod: CatchUpMethod.snapshot,
      );
      await lateNode.requestCatchUp(method: CatchUpMethod.snapshot);

      expect(seenMethod, CatchUpMethod.snapshot);
      expect(lateNode['alpha']!.toJson(), {
        'title': 'persisted',
        'tags': ['a', 'b'],
      });
      // Value snapshot remints list element ids (not the disk ids).
      final tags =
          (lateNode['alpha']!.toCrdtJson()['properties'] as Map)['tags'] as Map;
      final firstId = (tags['entries'] as List).first['id'] as String;
      expect(firstId, isNot('disk:0'));
      expect(firstId, startsWith('late:'));

      await persister.close();
      lateNode.close();
    });

    test('client can prefer CRDT catch-up and keep element ids', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('doc-persister-crdt-method-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json').writeAsString(
        jsonEncode(_minimalCrdtDoc(title: 'persisted', tags: ['a'])),
      );

      final server = WebSocketRelayServer(port: 0);
      await server.start();
      addTearDown(() async {
        await server.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      CatchUpMethod? seenMethod;
      final lateTransport = WebSocketClientTransport('late', server.wsUrl);
      await lateTransport.connect();
      lateTransport.onMessage.listen((m) {
        try {
          final json = jsonDecode(m) as Map<String, dynamic>;
          if (json['type'] == catchupSnapshotType) {
            seenMethod = CatchUpMethod.parse(json['method'] as String?);
          }
        } catch (_) {}
      });

      final lateNode = DocumentSyncNode(
        lateTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
        catchUpMethod: CatchUpMethod.crdt,
      );
      await lateNode.requestCatchUp(method: CatchUpMethod.crdt);

      expect(seenMethod, CatchUpMethod.crdt);
      final tags =
          (lateNode['alpha']!.toCrdtJson()['properties'] as Map)['tags'] as Map;
      expect((tags['entries'] as List).first['id'], 'disk:0');

      await persister.close();
      lateNode.close();
    });

    test('autoCatchUp: false skips catch-up on connect', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('doc-persister-no-auto-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json').writeAsString(
        jsonEncode(_minimalCrdtDoc(title: 'hidden', tags: ['z'])),
      );

      final server = WebSocketRelayServer(port: 0);
      await server.start();
      addTearDown(() async {
        await server.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final lateTransport = WebSocketClientTransport('late', server.wsUrl);
      await lateTransport.connect();
      final lateNode = DocumentSyncNode(
        lateTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
      );
      await lateNode.catchUp; // completes immediately
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(lateNode['alpha'], isNull);

      await lateNode.requestCatchUp();
      expect(lateNode['alpha']!.toJson()['title'], 'hidden');

      await persister.close();
      lateNode.close();
    });

    test('catch-up includes edits made after load', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('doc-persister-catchup2-');
      await File('${tempDir.path}/alpha-20260101T000000Z.json').writeAsString(
        jsonEncode(_minimalCrdtDoc(title: 'base', tags: ['a'])),
      );

      final server = WebSocketRelayServer(port: 0);
      await server.start();
      addTearDown(() async {
        await server.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final editorTransport = WebSocketClientTransport('editor', server.wsUrl);
      await editorTransport.connect();
      final editorNode = DocumentSyncNode(
        editorTransport,
        factory: (id, _) => DynamicSyncable(id),
        autoCatchUp: false,
      );

      final persister = DocumentPersister(
        wsUrl: server.wsUrl,
        directory: tempDir,
        interval: const Duration(hours: 1),
        nodeId: 'persister',
      );
      await persister.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final live = editorNode['alpha']! as DynamicSyncable;
      // Local mutation syncs to the persister, then appears in catch-up.
      live.applyJson({'tags': ['post-load']});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final lateTransport = WebSocketClientTransport('late', server.wsUrl);
      await lateTransport.connect();
      final lateNode = DocumentSyncNode(
        lateTransport,
        factory: (id, _) => DynamicSyncable(id),
      );
      await lateNode.catchUp;

      expect(lateNode['alpha']!.toJson()['tags'], contains('post-load'));
      expect(live.toJson()['tags'], contains('post-load'));

      await persister.close();
      editorNode.close();
      lateNode.close();
    });
  });

  group('InMemoryTransport unicast', () {
    test('sendTo delivers to one peer only', () {
      final hub = InMemoryTransportHub();
      final a = hub.createTransport('a');
      final b = hub.createTransport('b');
      final c = hub.createTransport('c');

      final receivedB = <String>[];
      final receivedC = <String>[];
      b.onMessage.listen(receivedB.add);
      c.onMessage.listen(receivedC.add);

      a.sendTo('b', 'only-b');
      a.send('broadcast');

      expect(receivedB, ['only-b', 'broadcast']);
      expect(receivedC, ['broadcast']);

      hub.close();
    });
  });
}
