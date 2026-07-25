import 'dart:io';

import 'package:logger/logger.dart';
import 'package:syncable_properties/syncable_properties_io.dart';

/// Run with:
/// `dart run bin/server.dart [port] [--persist-dir=<path>] [--persist-interval=<seconds>] [--persist-keep-versions] [--persist-as-of=<yyyyMMddTHHmmssZ>]`
void main(List<String> args) async {
  final parsed = _parseArgs(args);
  final logger = Logger();
  final server = WebSocketRelayServer(port: parsed.port);
  await server.start();
  logger.d('WebSocket relay server running on ${server.wsUrl}');

  final persistDir = parsed.persistDir;
  if (persistDir != null) {
    // Retained by its periodic timer for the process lifetime.
    final persister = DocumentPersister(
      wsUrl: server.wsUrl,
      directory: Directory(persistDir),
      interval: Duration(seconds: parsed.persistIntervalSeconds),
      keepVersions: parsed.persistKeepVersions,
      asOf: parsed.persistAsOf,
    );
    await persister.start();
    final asOfLabel = parsed.persistAsOf == null
        ? 'latest'
        : DocumentPersister.formatUtcStamp(parsed.persistAsOf!);
    logger.d(
      'Document persistence enabled: dir=$persistDir '
      'interval=${parsed.persistIntervalSeconds}s '
      'keepVersions=${parsed.persistKeepVersions} '
      'asOf=$asOfLabel '
      'loaded=${persister.documentsLoaded}',
    );
  }
}

class _Args {
  final int port;
  final String? persistDir;
  final int persistIntervalSeconds;
  final bool persistKeepVersions;
  final DateTime? persistAsOf;

  _Args({
    required this.port,
    required this.persistDir,
    required this.persistIntervalSeconds,
    required this.persistKeepVersions,
    required this.persistAsOf,
  });
}

_Args _parseArgs(List<String> args) {
  var port = 8080;
  String? persistDir;
  var persistIntervalSeconds = 60;
  var sawPersistInterval = false;
  var persistKeepVersions = false;
  DateTime? persistAsOf;
  var sawPersistAsOf = false;

  for (final arg in args) {
    if (arg.startsWith('--persist-dir=')) {
      persistDir = arg.substring('--persist-dir='.length);
      if (persistDir.isEmpty) {
        _usage('Empty --persist-dir value.');
      }
    } else if (arg.startsWith('--persist-interval=')) {
      sawPersistInterval = true;
      final raw = arg.substring('--persist-interval='.length);
      persistIntervalSeconds = int.tryParse(raw) ?? -1;
      if (persistIntervalSeconds <= 0) {
        _usage('Invalid --persist-interval: $raw');
      }
    } else if (arg == '--persist-keep-versions') {
      persistKeepVersions = true;
    } else if (arg.startsWith('--persist-as-of=')) {
      sawPersistAsOf = true;
      final raw = arg.substring('--persist-as-of='.length);
      persistAsOf = DocumentPersister.parseUtcStamp(raw);
      if (persistAsOf == null) {
        _usage('Invalid --persist-as-of: $raw (expected yyyyMMddTHHmmssZ)');
      }
    } else if (arg.startsWith('--')) {
      _usage('Unknown flag: $arg');
    } else {
      port = int.tryParse(arg) ?? -1;
      if (port <= 0) {
        _usage('Invalid port: $arg');
      }
    }
  }

  if (sawPersistInterval && persistDir == null) {
    _usage('--persist-interval requires --persist-dir.');
  }
  if (persistKeepVersions && persistDir == null) {
    _usage('--persist-keep-versions requires --persist-dir.');
  }
  if (sawPersistAsOf && persistDir == null) {
    _usage('--persist-as-of requires --persist-dir.');
  }

  return _Args(
    port: port,
    persistDir: persistDir,
    persistIntervalSeconds: persistIntervalSeconds,
    persistKeepVersions: persistKeepVersions,
    persistAsOf: persistAsOf,
  );
}

Never _usage(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage: dart run bin/server.dart [port] '
    '[--persist-dir=<path>] [--persist-interval=<seconds>] '
    '[--persist-keep-versions] [--persist-as-of=<yyyyMMddTHHmmssZ>]',
  );
  exit(64);
}
