import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

class TransferException implements Exception {
  TransferException(this.message, {this.unauthorized = false});

  final String message;
  final bool unauthorized;

  @override
  String toString() => message;
}

/// HTTP client side: talks to another phone's [ReceiveServer].
class PeerClient {
  PeerClient({required this.selfId, required this.key});

  final String selfId;
  final String Function() key;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20);

  Uri _uri(String host, int port, String path, [Map<String, String>? q]) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: path,
    queryParameters: q,
  );

  /// Returns the device at [host] or null if it's unreachable.
  Future<PeerInfo?> probe(String host, int port) async {
    try {
      final req = await _http.getUrl(_uri(host, port, '/info'));
      req.headers.set(Hdr.key, key());
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await utf8.decodeStream(res);
      return PeerInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Whether [peer] already has this asset from us (e.g. after a reinstall).
  Future<bool> has(Peer peer, String assetId) async {
    final req = await _http.getUrl(
      _uri(peer.host, peer.port, '/has', {'asset': assetId}),
    );
    req.headers
      ..set(Hdr.key, key())
      ..set(Hdr.sender, selfId);
    final res = await req.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decodeStream(res);
    _check(res.statusCode, body);
    return (jsonDecode(body) as Map<String, dynamic>)['has'] == true;
  }

  /// Streams [file] to [peer]. Returns `saved` or `duplicate`.
  Future<String> upload(
    Peer peer, {
    required String assetId,
    required File file,
    required String name,
    required String kind,
    required DateTime created,
    (double, double)? location,
    void Function(int sent, int total)? onProgress,
  }) async {
    final total = await file.length();
    final req = await _http.postUrl(_uri(peer.host, peer.port, '/upload'));
    req.contentLength = total;
    req.headers
      ..contentType = ContentType.binary
      ..set(Hdr.key, key())
      ..set(Hdr.sender, selfId)
      ..set(Hdr.assetId, assetId)
      ..set(Hdr.fileName, Uri.encodeComponent(name))
      ..set(Hdr.kind, kind)
      ..set(Hdr.created, created.millisecondsSinceEpoch.toString());
    if (location case (final lat, final lng)) {
      req.headers
        ..set(Hdr.lat, lat.toString())
        ..set(Hdr.lng, lng.toString());
    }

    var sent = 0;
    await req.addStream(
      file.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, total);
        return chunk;
      }),
    );
    // Big videos can take the receiver a while to write into its gallery.
    final res = await req.close().timeout(const Duration(minutes: 5));
    final body = await utf8.decodeStream(res);
    _check(res.statusCode, body);
    return (jsonDecode(body) as Map<String, dynamic>)['status'] as String;
  }

  void _check(int status, String body) {
    if (status == 200) return;
    if (status == 401) {
      throw TransferException('Pairing code mismatch', unauthorized: true);
    }
    var msg = 'HTTP $status';
    try {
      msg = (jsonDecode(body) as Map<String, dynamic>)['error'] as String;
    } catch (_) {}
    throw TransferException(msg);
  }

  void close() => _http.close(force: true);
}
