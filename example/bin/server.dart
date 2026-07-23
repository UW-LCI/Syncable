// ignore_for_file: avoid_print


import 'dart:io';

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('WebSocket relay server running on ws://localhost:8080');

  final clients = <WebSocket>[];

  await for (final request in server) {
    if (request.uri.path == '/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      clients.add(socket);
      print('Client connected. Total clients: ${clients.length}');

      socket.listen(
        (data) {
          final message = data as String;
          for (final client in clients) {
            if (client != socket && client.readyState == WebSocket.open) {
              client.add(message);
            }
          }
        },
        onDone: () {
          clients.remove(socket);
          print('Client disconnected. Total clients: ${clients.length}');
        },
        onError: (error) {
          clients.remove(socket);
          print('Client error: $error. Total clients: ${clients.length}');
        },
      );
    }
  }
}