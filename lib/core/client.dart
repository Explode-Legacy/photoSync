import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crypto.dart';
import 'identity.dart';
import 'protocol.dart';
import 'server.dart' show DateFix, ReceiveServer, TrustedDevice;

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
  _Outgoing(this.req, this.nonce, this.sealer, this.keys);

  final HttpClientRequest req;
  final String nonce;
  final Sealer sealer;
  final ChannelKeys keys;
}

/// Our side of a session with one device.
class _ClientSession {
  _ClientSession(this.id, this.keys);

  final String id;
  final ChannelKeys keys;
  final DateTime created = DateTime.now();
}

/// The other side no longer knows our session (it restarted): start a new
/// one and retry.
class _SessionLost implements Exception {}

/// HTTP client side: talks to another device's [ReceiveServer].
class PeerClient {
  PeerClient({
    required this.selfId,
    required this.selfName,
    required this.identity,
    required this.trusted,
    required this.pairingCode,
    required this.onPaired,
    this.selfPort,
  });

  final String selfId;
  final String Function() selfName;
  final DeviceIdentity identity;
  final TrustedDevice? Function(String id) trusted;

  /// The stretched pairing code (see [CodeSecret.stretch]).
  final Future<List<int>> Function() pairingCode;

  /// Pairing succeeded: trust this device's key from now on.
  final Future<void> Function(String id, String name, List<int> publicKey)
  onPaired;

  /// Our server's port, sent so the other side can reach us back.
  final int Function()? selfPort;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20);

  final Map<String, _ClientSession> _sessions = {};
  final Map<String, DateTime> _pairBackoff = {};

  Uri _uri(String host, int port, String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  /// Forgets sessions (all, or with one device), e.g. after unpairing.
  void dropSessions([String? peerId]) {
    if (peerId == null) {
      _sessions.clear();
      _pairBackoff.clear();
    } else {
      _sessions.remove(peerId);
      _pairBackoff.remove(peerId);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String host,
    int port,
    String path,
    Map<String, dynamic> body,
  ) async {
    final req = await _http.postUrl(_uri(host, port, path));
    req.headers
      ..contentType = ContentType.json
      ..set(Hdr.sender, selfId);
    final ourPort = selfPort?.call() ?? 0;
    if (ourPort > 0) req.headers.set(Hdr.port, '$ourPort');
    req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await utf8.decodeStream(res);
    final json = text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
    if (res.statusCode == 401) {
      throw TransferException('Pairing code mismatch', unauthorized: true);
    }
    if (res.statusCode == 429) {
      throw TransferException('Too many wrong pairing codes; wait a minute');
    }
    if (res.statusCode != 200) {
      throw TransferException(
        json['error'] as String? ?? 'HTTP ${res.statusCode}',
      );
    }
    return json;
  }

  /// SPAKE2 with the device at [host]: proves we share the pairing code
  /// and swaps identity keys. Returns false when the codes differ.
  Future<bool> pair(String host, int port, PeerInfo info) async {
    final a = Spake2.start(await pairingCode(), initiator: true);
    final reply = await _postJson(host, port, '/pair', {
      'id': selfId,
      'name': selfName(),
      'pub': identity.publicKeyText,
      'share': base64Url.encode(a.message),
    });
    final pubB = base64Url.decode(reply['pub'] as String);
    // The key it advertised must be the one it pairs with.
    if (info.publicKey.isNotEmpty && reply['pub'] != info.publicKey) {
      return false;
    }
    final shareB = base64Url.decode(reply['share'] as String);
    final transcript = pairingTranscript(
      idA: selfId,
      pubA: identity.publicKey,
      idB: info.id,
      pubB: pubB,
      shareA: a.message,
      shareB: shareB,
      k: a.sharedKey(shareB),
      w: a.wBytes,
    );
    final ok = constantTimeEquals(
      utf8.encode(await pairingConfirm(transcript, 'B')),
      utf8.encode(reply['confirm'] as String? ?? ''),
    );
    if (!ok) return false; // different code: send no proof of ours
    await _postJson(host, port, '/pair/confirm', {
      'pair': reply['pair'],
      'confirm': await pairingConfirm(transcript, 'A'),
    });
    await onPaired(info.id, info.name, pubB);
    _sessions.remove(info.id);
    return true;
  }

  /// A session with [peerId] at [host], reusing a recent one.
  Future<_ClientSession> _session(String host, int port, String peerId) async {
    final existing = _sessions[peerId];
    if (existing != null &&
        DateTime.now().difference(existing.created) <
            ReceiveServer.sessionLifetime) {
      return existing;
    }
    final known = trusted(peerId);
    if (known == null) {
      throw TransferException('Not paired', unauthorized: true);
    }
    final eph = await newEphemeral();
    final ephI = (await eph.extractPublicKey()).bytes;
    final reply = await _postJson(host, port, '/session', {
      'id': selfId,
      'eph': base64Url.encode(ephI),
    });
    final (keys, h) = await kkSession(
      initiator: true,
      idI: selfId,
      idR: peerId,
      staticI: identity.publicKey,
      staticR: known.publicKey,
      ephemeralI: ephI,
      ephemeralR: base64Url.decode(reply['eph'] as String),
      myStatic: identity.keyPair,
      myEphemeral: eph,
    );
    // Only the real device (holding its identity key) can produce this.
    final good = await keys.verify(
      'pb3/session-ok|${base64Url.encode(h)}',
      reply['confirm'] as String? ?? '',
    );
    if (!good) {
      throw TransferException('Device key mismatch', unauthorized: true);
    }
    return _sessions[peerId] = _ClientSession(reply['session'] as String, keys);
  }

  /// Opens [method] [path] to [peerId], signs it with our session and
  /// attaches encrypted [meta].
  Future<_Outgoing> _open(
    String method,
    String host,
    int port,
    String peerId,
    String path, {
    Map<String, dynamic>? meta,
  }) async {
    final session = await _session(host, port, peerId);
    final uri = _uri(host, port, path);
    final req = await _http.openUrl(method, uri);
    final salt = randomToken();
    final sealer = await session.keys.sealer(base64Url.decode(salt));
    final sealedMeta = meta == null ? '' : await sealer.sealJson(meta);
    final ts = '${DateTime.now().millisecondsSinceEpoch}';
    final nonce = randomToken();
    req.headers
      ..set(Hdr.sender, selfId)
      ..set(Hdr.session, session.id)
      ..set(Hdr.ts, ts)
      ..set(Hdr.nonce, nonce)
      ..set(Hdr.salt, salt);
    if (sealedMeta.isNotEmpty) req.headers.set(Hdr.meta, sealedMeta);
    final ourPort = selfPort?.call() ?? 0;
    if (ourPort > 0) req.headers.set(Hdr.port, '$ourPort');
    req.headers.set(
      Hdr.auth,
      await session.keys.sign(
        signedRequest(
          method: method,
          target: requestTarget(uri),
          ts: ts,
          nonce: nonce,
          sender: '$selfId|${session.id}',
          salt: salt,
          meta: sealedMeta,
        ),
      ),
    );
    return _Outgoing(req, nonce, sealer, session.keys);
  }

  /// Runs [call]; if the other side lost our session, starts a new one and
  /// runs it once more.
  Future<T> _retrying<T>(String peerId, Future<T> Function() call) async {
    try {
      return await call();
    } on _SessionLost {
      _sessions.remove(peerId);
      return call();
    }
  }

  /// Reads the reply and checks it's signed with our session.
  Future<(int, Map<String, dynamic>, bool)> _read(
    HttpClientResponse res,
    _Outgoing o,
  ) async {
    final body = await utf8.decodeStream(res);
    final sig = res.headers.value(Hdr.sig);
    final trusted =
        sig != null &&
        await o.keys.verify(signedResponse(o.nonce, res.statusCode, body), sig);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      json = {};
    }
    return (res.statusCode, json, trusted);
  }

  /// Returns the device at [host] or null if it's unreachable. `paired`
  /// is true once we trust its key and a session with it works; a new
  /// device with the same pairing code is paired on the way.
  Future<PeerInfo?> probe(String host, int port) async {
    PeerInfo info;
    try {
      final req = await _http.getUrl(_uri(host, port, '/info'));
      req.headers.set(Hdr.sender, selfId);
      final res = await req.close().timeout(const Duration(seconds: 4));
      final body = await utf8.decodeStream(res);
      if (res.statusCode != 200) return null;
      info = PeerInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
    if (info.id == selfId || info.version < kProtocolVersion) {
      return info.withPaired(false);
    }
    try {
      final known = trusted(info.id);
      final sameKey =
          known != null && base64Url.encode(known.publicKey) == info.publicKey;
      if (!sameKey) {
        // New device, or it was reinstalled: pair with the code, but don't
        // hammer one that has a different code.
        final wait = _pairBackoff[info.id];
        if (wait != null && DateTime.now().isBefore(wait)) {
          return info.withPaired(false);
        }
        if (!await pair(host, port, info)) {
          _pairBackoff[info.id] = DateTime.now().add(
            const Duration(minutes: 5),
          );
          return info.withPaired(false);
        }
      }
      await _session(host, port, info.id);
      return info.withPaired(true);
    } on TransferException catch (e) {
      if (e.unauthorized) _sessions.remove(info.id);
      _pairBackoff[info.id] = DateTime.now().add(const Duration(minutes: 1));
      return info.withPaired(false);
    } catch (_) {
      return info.withPaired(false);
    }
  }

  /// Whether [peer] still has this asset from us, and how many bytes of an
  /// interrupted upload of it it holds.
  Future<({bool has, int offset})> status(Peer peer, String assetId) =>
      _retrying(peer.info.id, () async {
        final o = await _open(
          'GET',
          peer.host,
          peer.port,
          peer.info.id,
          '/status',
          meta: {'asset': assetId},
        );
        final res = await o.req.close().timeout(const Duration(seconds: 10));
        final json = _checked(await _read(res, o));
        return (has: json['has'] == true, offset: json['offset'] as int? ?? 0);
      });

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
    return _retrying(
      peer.info.id,
      () => _upload(
        peer,
        assetId: assetId,
        file: file,
        name: name,
        kind: kind,
        created: created,
        location: location,
        dir: dir,
        album: album,
        onProgress: onProgress,
        size: size,
        offset: offset,
      ),
    );
  }

  Future<String> _upload(
    Peer peer, {
    required String assetId,
    required File file,
    required String name,
    required String kind,
    required DateTime created,
    required (double, double)? location,
    required String? dir,
    required String? album,
    required void Function(int sent, int total)? onProgress,
    required int size,
    required int offset,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final o = await _open(
        'POST',
        peer.host,
        peer.port,
        peer.info.id,
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
      final reply = await _read(res, o);
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
    return _retrying(peer.info.id, () async {
      final o = await _open(
        'POST',
        peer.host,
        peer.port,
        peer.info.id,
        '/fixdates',
      );
      o.req
        ..contentLength = sealedLength(body.length)
        ..headers.contentType = ContentType.binary;
      await o.req.addStream(o.sealer.sealBytes(body));
      final res = await o.req.close().timeout(const Duration(minutes: 2));
      return _checked(await _read(res, o))['fixed'] as int? ?? 0;
    });
  }

  Map<String, dynamic> _checked((int, Map<String, dynamic>, bool) reply) {
    final (status, json, trusted) = reply;
    if (status == 401 && json['error'] == 'session') throw _SessionLost();
    if (status == 401) {
      throw TransferException(
        'Not paired with this device',
        unauthorized: true,
      );
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
