import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crypto.dart';
import 'protocol.dart';
import 'server.dart' show DateFix;

class TransferException implements Exception {
  TransferException(
    this.message, {
    this.unauthorized = false,
    this.rejected = false,
  });

  final String message;
  final bool unauthorized;

  /// The receiver turned off inbound photos.
  final bool rejected;

  @override
  String toString() => message;
}

/// A signed request ready to send, with its encryption context.
class _Outgoing {
  _Outgoing(this.req, this.nonce, this.sealer);

  final HttpClientRequest req;
  final String nonce;
  final Sealer sealer;
}

/// HTTP client side: talks to another device's [ReceiveServer].
class PeerClient {
  PeerClient({required this.selfId, required this.keys, this.selfPort});

  final String selfId;

  /// Keys for the current pairing code.
  final Future<PairKeys> Function() keys;

  /// Our server's port, sent so the other side can reach us back.
  final int Function()? selfPort;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20);

  Uri _uri(String host, int port, String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  /// Opens [method] [path], signs it and attaches encrypted [meta].
  Future<_Outgoing> _open(
    String method,
    String host,
    int port,
    String path, {
    Map<String, dynamic>? meta,
  }) async {
    final uri = _uri(host, port, path);
    final req = await _http.openUrl(method, uri);
    final k = await keys();
    final salt = randomToken();
    final sealer = await k.sealer(base64Url.decode(salt));
    final sealedMeta = meta == null ? '' : await sealer.sealJson(meta);
    final ts = '${DateTime.now().millisecondsSinceEpoch}';
    final nonce = randomToken();
    req.headers
      ..set(Hdr.sender, selfId)
      ..set(Hdr.ts, ts)
      ..set(Hdr.nonce, nonce)
      ..set(Hdr.salt, salt);
    if (sealedMeta.isNotEmpty) req.headers.set(Hdr.meta, sealedMeta);
    final ourPort = selfPort?.call() ?? 0;
    if (ourPort > 0) req.headers.set(Hdr.port, '$ourPort');
    req.headers.set(
      Hdr.auth,
      await k.sign(
        signedRequest(
          method: method,
          target: requestTarget(uri),
          ts: ts,
          nonce: nonce,
          sender: selfId,
          salt: salt,
          meta: sealedMeta,
        ),
      ),
    );
    return _Outgoing(req, nonce, sealer);
  }

  /// Reads the reply and checks it's signed by someone with our code.
  Future<(int, Map<String, dynamic>, bool)> _read(
    HttpClientResponse res,
    String nonce,
  ) async {
    final body = await utf8.decodeStream(res);
    final sig = res.headers.value(Hdr.sig);
    final k = await keys();
    final trusted =
        sig != null &&
        await k.verify(signedResponse(nonce, res.statusCode, body), sig);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      json = {};
    }
    return (res.statusCode, json, trusted);
  }

  /// Returns the device at [host] or null if it's unreachable. `paired` is
  /// true only when its reply carries a valid signature.
  Future<PeerInfo?> probe(String host, int port) async {
    try {
      final o = await _open('GET', host, port, '/info');
      final res = await o.req.close().timeout(const Duration(seconds: 4));
      final (status, json, trusted) = await _read(res, o.nonce);
      if (status != 200) return null;
      return PeerInfo.fromJson(json).withPaired(trusted);
    } catch (_) {
      return null;
    }
  }

  /// Whether [peer] still has this asset from us, and how many bytes of an
  /// interrupted upload of it it holds.
  Future<({bool has, int offset})> status(Peer peer, String assetId) async {
    final o = await _open(
      'GET',
      peer.host,
      peer.port,
      '/status',
      meta: {'asset': assetId},
    );
    final res = await o.req.close().timeout(const Duration(seconds: 10));
    final json = _checked(await _read(res, o.nonce));
    return (has: json['has'] == true, offset: json['offset'] as int? ?? 0);
  }

  Future<bool> has(Peer peer, String assetId) async =>
      (await status(peer, assetId)).has;

  /// Encrypts and streams [file] to [peer], resuming an earlier attempt if
  /// the receiver kept part of it. Returns `saved` or `duplicate`.
  ///
  /// [kind] is `image`, `video` (saved to the gallery) or `file` (saved
  /// under [dir] in the receiver's files folder).
  Future<String> upload(
    Peer peer, {
    required String assetId,
    required File file,
    required String name,
    required String kind,
    required DateTime created,
    (double, double)? location,
    String? dir,
    String? album,
    void Function(int sent, int total)? onProgress,
  }) async {
    final size = await file.length();
    var offset = 0;
    if (size > kChunkSize) {
      final s = await status(peer, assetId);
      if (s.has) return 'duplicate';
      offset = s.offset <= size ? s.offset : 0;
    }
    for (var attempt = 0; ; attempt++) {
      final o = await _open(
        'POST',
        peer.host,
        peer.port,
        '/upload',
        meta: {
          'asset': assetId,
          'name': name,
          'kind': kind,
          'created': created.millisecondsSinceEpoch,
          'size': size,
          'offset': offset,
          if (location case (final lat, final lng)) ...{'lat': lat, 'lng': lng},
          if (dir != null && dir.isNotEmpty) 'dir': dir,
          if (album != null && album.isNotEmpty) 'album': album,
        },
      );
      o.req
        ..contentLength = sealedLength(size - offset)
        ..headers.contentType = ContentType.binary;
      onProgress?.call(offset, size);
      await o.req.addStream(
        o.sealer.sealFile(
          file,
          offset: offset,
          onPlain: (n) => onProgress?.call(n, size),
        ),
      );
      // Big videos can take the receiver a while to write into its gallery.
      final res = await o.req.close().timeout(const Duration(minutes: 5));
      final reply = await _read(res, o.nonce);
      // The receiver's partial copy didn't match: start where it says.
      if (reply.$1 == 409 && attempt == 0 && reply.$3) {
        offset = reply.$2['offset'] as int? ?? 0;
        continue;
      }
      return _checked(reply)['status'] as String;
    }
  }

  /// Sends corrected capture dates for photos sent earlier; returns how
  /// many the receiver fixed.
  Future<int> fixDates(Peer peer, List<DateFix> fixes) async {
    final body = utf8.encode(
      jsonEncode([
        for (final f in fixes)
          {
            'name': f.name,
            'created': f.created.millisecondsSinceEpoch,
            if (f.location case (final lat, final lng)) ...{
              'lat': lat,
              'lng': lng,
            },
          },
      ]),
    );
    final o = await _open('POST', peer.host, peer.port, '/fixdates');
    o.req
      ..contentLength = sealedLength(body.length)
      ..headers.contentType = ContentType.binary;
    await o.req.addStream(o.sealer.sealBytes(body));
    final res = await o.req.close().timeout(const Duration(minutes: 2));
    return _checked(await _read(res, o.nonce))['fixed'] as int? ?? 0;
  }

  Map<String, dynamic> _checked((int, Map<String, dynamic>, bool) reply) {
    final (status, json, trusted) = reply;
    if (status == 401) {
      throw TransferException('Pairing code mismatch', unauthorized: true);
    }
    if (status == 429) {
      throw TransferException('Too many wrong pairing codes; wait a minute');
    }
    if (!trusted) {
      throw TransferException('Reply was not signed with our pairing code');
    }
    if (status == 200) return json;
    if (status == 403) {
      throw TransferException('Inbound is off there', rejected: true);
    }
    throw TransferException(json['error'] as String? ?? 'HTTP $status');
  }

  void close() => _http.close(force: true);
}
