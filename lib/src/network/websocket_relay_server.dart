import 'dart:async';
import 'dart:io';

import 'transport.dart';

/// A WebSocket relay for syncable_properties clients.
///
/// Each connection's first text frame is treated as a [nodeId] handshake and
/// is not forwarded. Later frames are broadcast to every other connected
/// client, unless they are unicast wrappers (`$to` / `$msg`), in which case
/// the inner payload is delivered only to the named peer.
class WebSocketRelayServer {
  final InternetAddress address;
  final int port;
  final String path;

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final Map<String, WebSocket> _clientsByNodeId = {};

  WebSocketRelayServer({
    InternetAddress? address,
    this.port = 5582,
    this.path = '/ws',
  }) : address = address ?? InternetAddress.loopbackIPv4;

  /// Bound port after [start]. Useful when [port] was `0` (ephemeral).
  int get boundPort {
    final server = _server;
    if (server == null) {
      throw StateError('WebSocketRelayServer has not been started.');
    }
    return server.port;
  }

  /// `ws://host:port/path` URL clients should connect to.
  String get wsUrl {
    final host = address.address;
    return 'ws://$host:$boundPort$path';
  }

  Future<void> start() async {
    if (_server != null) {
      throw StateError('WebSocketRelayServer is already running.');
    }
    _server = await HttpServer.bind(address, port);
    _server!.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != path) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    _clients.add(socket);

    String? nodeId;
    socket.listen(
      (data) {
        if (data is! String) return;
        if (nodeId == null) {
          nodeId = data;
          _clientsByNodeId[nodeId!] = socket;
          return;
        }

        final directed = parseUnicastWrapper(data);
        if (directed != null) {
          final target = _clientsByNodeId[directed.to];
          if (target != null &&
              target != socket &&
              target.readyState == WebSocket.open) {
            target.add(directed.msg);
          }
          return;
        }

        for (final client in _clients) {
          if (client != socket && client.readyState == WebSocket.open) {
            client.add(data);
          }
        }
      },
      onDone: () => _removeClient(socket, nodeId),
      onError: (_) => _removeClient(socket, nodeId),
      cancelOnError: true,
    );
  }

  void _removeClient(WebSocket socket, String? nodeId) {
    _clients.remove(socket);
    if (nodeId != null && _clientsByNodeId[nodeId] == socket) {
      _clientsByNodeId.remove(nodeId);
    }
  }

  Future<void> close() async {
    final clients = List<WebSocket>.from(_clients);
    _clients.clear();
    _clientsByNodeId.clear();
    for (final client in clients) {
      await client.close();
    }
    await _server?.close(force: true);
    _server = null;
  }
}
