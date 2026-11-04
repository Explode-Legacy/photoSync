import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:path_provider/path_provider.dart';

import 'crypto.dart';
import 'identity.dart';
import 'protocol.dart';

/// A file fully received, decrypted and written to a temp path, ready to be
/// saved.
class IncomingFile {
  IncomingFile({
    required this.senderId,
    required this.assetId,
    required this.name,
    required this.kind,
    required this.created,
    required this.location,
    this.dir = '',
    this.album = '',
    required this.file,
  });

  final String senderId;
  final String assetId;
  final String name;

  /// `image`, `video` or `file`.
  final String kind;
  final DateTime? created;

  /// (latitude, longitude) from the sender's library, if it had one.
  final (double, double)? location;

  /// For files: sanitized relative folder (`a/b`), or empty.
  final String dir;

  /// For photos: the sender's album, sanitized, or empty.
  final String album;
  final File file;
}

/// A corrected capture date for a photo sent earlier (`POST /fixdates`).
typedef DateFix = ({String name, DateTime created, (double, double)? location});

/// A request that passed the signature check of its session.
class _Signed {
  _Signed(this.sender, this.nonce, this.keys, this.sealer, this.meta);

  final String sender;
  final String nonce;
  final ChannelKeys keys;
  final Sealer? sealer;
  final Map<String, dynamic> meta;
}

/// A trusted device's identity key and the name it had when paired.
typedef TrustedDevice = ({List<int> publicKey, String name});

/// An established session: who it's with and its keys.
class _Session {
  _Session(this.peerId, this.keys);

  final String peerId;
  final ChannelKeys keys;
  final DateTime created = DateTime.now();
}

/// SPAKE2 waiting for the initiator's confirmation.
class _PendingPair {
  _PendingPair(this.id, this.name, this.publicKey, this.transcript);

  final String id;
  final String name;
  final List<int> publicKey;
  final List<int> transcript;
  final DateTime created = DateTime.now();
}

/// HTTP server that accepts photos and files from paired devices.
class ReceiveServer {
  ReceiveServer({
    required this.selfInfo,
    required this.identity,
    required this.trusted,
    required this.pairingCode,
    required this.onPaired,
    required this.alreadyHave,
    required this.onFile,
    this.acceptsPhotos = _always,
    this.onReceiving,
    this.onContact,
    this.onFixDates,
    this.tempRoot,
  });

  static bool _always() => true;

  /// Returns this device's id/name/os/inbound for `GET /info`.
  final Map<String, dynamic> Function() selfInfo;

  /// This device's identity key pair.
  final DeviceIdentity identity;

  /// The device we trust under [id] (from an earlier pairing), or null.
  final TrustedDevice? Function(String id) trusted;

  /// The stretched pairing code (see [CodeSecret.stretch]).
  final Future<List<int>> Function() pairingCode;

  /// A device proved it knows the pairing code: trust its key from now on.
  final Future<void> Function(String id, String name, List<int> publicKey)
  onPaired;

  /// Whether we still hold this asset from that sender.
  final Future<bool> Function(String senderId, String assetId) alreadyHave;

  /// Saves the file to the gallery. The temp file is deleted afterwards.
  final Future<void> Function(IncomingFile file) onFile;

  /// False rejects photos and videos (the "Allow inbound" setting).
  final bool Function() acceptsPhotos;

  /// Upload progress as bytes arrive: [received] of [total] plaintext
  /// bytes. Called with `done: true` once, when the upload ends either way.
  final void Function(
    String key,
    String senderId,
    String name,
    int received,
    int total, {
    bool done,
  })?
  onReceiving;

  /// A paired device reached us from [host]; its server listens on [port].
  /// Lets us connect back even when we didn't know its address (e.g. it
  /// came in over Tailscale, or its Wi-Fi address changed).
  final void Function(String senderId, String host, int port)? onContact;

  /// Applies corrected dates; returns how many photos were fixed.
  final Future<int> Function(String senderId, List<DateFix> fixes)? onFixDates;

  /// Where uploads are staged; defaults to the app's temp directory.
  final Directory? tempRoot;

  HttpServer? _server;
  late Directory _tmp;
  late Directory _partial;

  int get port => _server?.port ?? 0;

  final Map<String, _Session> _sessions = {};
  final Map<String, _PendingPair> _pairs = {};

  /// Sessions are replaced this often; their throwaway keys are forgotten.
  static const sessionLifetime = Duration(minutes: 10);

  /// Ends sessions with [peerId] (e.g. after forgetting that device), or all.
  void dropSessions([String? peerId]) =>
      _sessions.removeWhere((_, s) => peerId == null || s.peerId == peerId);

  /// Nonces seen in the last [_maxSkew], so a captured request can't be
  /// replayed.
  final Map<String, int> _seen = {};
  static const _maxSkew = Duration(minutes: 5);

  /// Wrong-code attempts per address; [_maxFailures] in [_failWindow]
  /// locks that address out for [_lockout].
  final Map<String, List<int>> _failures = {};
  final Map<String, int> _lockedUntil = {};
  static const _maxFailures = 10;
  static const _failWindow = Duration(minutes: 1);
  static const _lockout = Duration(minutes: 1);

  Future<void> start() async {
    final root = tempRoot ?? await getTemporaryDirectory();
    _tmp = Directory('${root.path}/incoming');
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
    await _tmp.create(recursive: true);
    // Interrupted uploads are kept a few days so they can resume.
    _partial = Directory('${root.path}/partial');
    await _partial.create(recursive: true);
    unawaited(_pruneOldPartials());
    // anyIPv6 also accepts IPv4. Fall back to IPv4 only, then to any free
    // port if the default one is taken (the UI shows the actual port).
    for (final (addr, port) in [
      (InternetAddress.anyIPv6, kDefaultPort),
      (InternetAddress.anyIPv4, kDefaultPort),
      (InternetAddress.anyIPv4, 0),
    ]) {
      try {
        _server = await HttpServer.bind(addr, port);
        break;
      } on SocketException {
        continue;
      }
    }
    if (_server == null) throw const SocketException('Could not open a port');
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _pruneOldPartials() async {
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    try {
      await for (final f in _partial.list()) {
        if (f is File && (await f.lastModified()).isBefore(cutoff)) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  static String _remoteHost(HttpRequest req) {
    var host = req.connectionInfo?.remoteAddress.address ?? '';
    // Dual-stack sockets report IPv4 callers as ::ffff:a.b.c.d.
    if (host.startsWith('::ffff:')) host = host.substring(7);
    return host;
  }

  bool _locked(String host) {
    final until = _lockedUntil[host];
    if (until == null) return false;
    if (DateTime.now().millisecondsSinceEpoch < until) return true;
    _lockedUntil.remove(host);
    return false;
  }

  void _recordFailure(String host) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = _failures.putIfAbsent(host, () => [])
      ..removeWhere((t) => now - t > _failWindow.inMilliseconds)
      ..add(now);
    if (list.length >= _maxFailures) {
      _lockedUntil[host] = now + _lockout.inMilliseconds;
      list.clear();
    }
  }

  /// Checks the request against its session and decrypts the metadata.
  /// Null when it has no valid session or signature.
  Future<_Signed?> _verify(HttpRequest req) async {
    final h = req.headers;
    final sender = h.value(Hdr.sender);
    final sessionId = h.value(Hdr.session);
    final tsText = h.value(Hdr.ts);
    final nonce = h.value(Hdr.nonce);
    final sig = h.value(Hdr.auth);
    if (sender == null ||
        sessionId == null ||
        tsText == null ||
        nonce == null ||
        sig == null) {
      return null;
    }
    final session = _sessions[sessionId];
    if (session == null ||
        session.peerId != sender ||
        DateTime.now().difference(session.created) > sessionLifetime * 2) {
      return null;
    }
    final ts = int.tryParse(tsText) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - ts).abs() > _maxSkew.inMilliseconds) return null;
    final salt = h.value(Hdr.salt) ?? '';
    final meta = h.value(Hdr.meta) ?? '';
    final ok = await session.keys.verify(
      signedRequest(
        method: req.method,
        target: requestTarget(req.uri),
        ts: tsText,
        nonce: nonce,
        sender: '$sender|$sessionId',
        salt: salt,
        meta: meta,
      ),
      sig,
    );
    if (!ok) {
      _recordFailure(_remoteHost(req));
      return null;
    }
    _seen.removeWhere((_, t) => now - t > _maxSkew.inMilliseconds * 2);
    if (_seen.containsKey(nonce)) return null;
    _seen[nonce] = now;

    final sealer = salt.isEmpty
        ? null
        : await session.keys.sealer(base64Url.decode(salt));
    final m = sealer == null || meta.isEmpty
        ? <String, dynamic>{}
        : await sealer.openJson(meta);
    return _Signed(sender, nonce, session.keys, sealer, m);
  }

  static Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    // Handshake bodies are tiny; refuse anything big.
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > 16 * 1024) throw const CryptoException('Too large');
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  /// SPAKE2, responder side: answer with our share, key and confirmation.
  Future<void> _pairStart(HttpRequest req) async {
    final j = await _readJson(req);
    final id = j['id'] as String? ?? '';
    final pubA = base64Url.decode(j['pub'] as String? ?? '');
    final shareA = base64Url.decode(j['share'] as String? ?? '');
    if (id.isEmpty || pubA.length != 32) {
      return _reply(req, null, 400, {'error': 'bad pairing request'});
    }
    // Each attempt is one guess at the code: count it until confirmed.
    _recordFailure(_remoteHost(req));
    final b = Spake2.start(await pairingCode(), initiator: false);
    final k = b.sharedKey(shareA);
    final transcript = pairingTranscript(
      idA: id,
      pubA: pubA,
      idB: selfInfo()['id'] as String,
      pubB: identity.publicKey,
      shareA: shareA,
      shareB: b.message,
      k: k,
      w: b.wBytes,
    );
    final pairId = randomToken();
    _pairs.removeWhere(
      (_, p) =>
          DateTime.now().difference(p.created) > const Duration(minutes: 1),
    );
    _pairs[pairId] = _PendingPair(
      id,
      j['name'] as String? ?? id,
      pubA,
      transcript,
    );
    await _reply(req, null, 200, {
      'pair': pairId,
      'pub': identity.publicKeyText,
      'share': base64Url.encode(b.message),
      'confirm': await pairingConfirm(transcript, 'B'),
    });
  }

  /// SPAKE2, last step: the initiator's confirmation proves its code.
  Future<void> _pairConfirm(HttpRequest req) async {
    final j = await _readJson(req);
    final pending = _pairs.remove(j['pair'] as String? ?? '');
    if (pending == null) {
      return _reply(req, null, 400, {'error': 'pairing expired'});
    }
    final expected = await pairingConfirm(pending.transcript, 'A');
    final given = j['confirm'] as String? ?? '';
    if (!constantTimeEquals(utf8.encode(expected), utf8.encode(given))) {
      _recordFailure(_remoteHost(req));
      return _reply(req, null, 401, {'error': 'pair'});
    }
    _failures.remove(_remoteHost(req));
    await onPaired(pending.id, pending.name, pending.publicKey);
    dropSessions(pending.id);
    await _reply(req, null, 200, {'ok': true});
  }

  /// Noise KK, responder side, for a device we already trust.
  Future<void> _session(HttpRequest req) async {
    final j = await _readJson(req);
    final id = j['id'] as String? ?? '';
    final ephI = base64Url.decode(j['eph'] as String? ?? '');
    final known = trusted(id);
    if (known == null || ephI.length != 32) {
      return _reply(req, null, 401, {'error': 'pair'});
    }
    final eph = await newEphemeral();
    final ephR = (await eph.extractPublicKey()).bytes;
    final (keys, h) = await kkSession(
      initiator: false,
      idI: id,
      idR: selfInfo()['id'] as String,
      staticI: known.publicKey,
      staticR: identity.publicKey,
      ephemeralI: ephI,
      ephemeralR: ephR,
      myStatic: identity.keyPair,
      myEphemeral: eph,
    );
    // A trusted device is starting a session: we can reach it back there.
    // (Spoofing this only makes us probe an address, which then fails.)
    onContact?.call(
      id,
      _remoteHost(req),
      int.tryParse(req.headers.value(Hdr.port) ?? '') ?? kDefaultPort,
    );
    final sessionId = randomToken();
    _sessions.removeWhere(
      (_, s) => DateTime.now().difference(s.created) > sessionLifetime * 2,
    );
    _sessions[sessionId] = _Session(id, keys);
    await _reply(req, null, 200, {
      'session': sessionId,
      'eph': base64Url.encode(ephR),
      // Proves we hold our identity key (the client checks it).
      'confirm': await keys.sign('pb3/session-ok|${base64Url.encode(h)}'),
    });
  }

  void _noteContact(HttpRequest req, _Signed s) {
    final port =
        int.tryParse(req.headers.value(Hdr.port) ?? '') ?? kDefaultPort;
    onContact?.call(s.sender, _remoteHost(req), port);
  }

  Future<void> _handle(HttpRequest req) async {
    _Signed? signed;
    try {
      if (_locked(_remoteHost(req))) {
        await req.drain<void>();
        return await _reply(req, null, 429, {'error': 'too many attempts'});
      }
      signed = await _verify(req);
      if (signed != null) _noteContact(req, signed);
      switch ((req.method, req.uri.path)) {
        case ('GET', '/info'):
          final caller = req.headers.value(Hdr.sender);
          await _reply(req, signed, 200, {
            ...selfInfo(),
            'v': kProtocolVersion,
            'pub': identity.publicKeyText,
            // Informational: whether we trust the caller's id.
            'paired': caller != null && trusted(caller) != null,
          });
        case ('POST', '/pair'):
          await _pairStart(req);
        case ('POST', '/pair/confirm'):
          await _pairConfirm(req);
        case ('POST', '/session'):
          await _session(req);
        case ('GET', '/status') when signed != null:
          final asset = signed.meta['asset'] as String? ?? '';
          final part = await _partialFile(signed.sender, asset);
          final held = await part.exists() ? await part.length() : 0;
          await _reply(req, signed, 200, {
            'has': await alreadyHave(signed.sender, asset),
            'offset': held - held % kChunkSize,
          });
        case ('POST', '/upload') when signed != null:
          await _upload(req, signed);
        case ('POST', '/fixdates') when signed != null:
          await _fixDates(req, signed);
        case (_, '/status' || '/upload' || '/fixdates'):
          await req.drain<void>();
          // The client starts a new session (or pairs) and retries.
          await _reply(req, null, 401, {'error': 'session'});
        default:
          await req.drain<void>();
          await _reply(req, null, 404, {'error': 'not found'});
      }
    } catch (e) {
      try {
        await _reply(req, signed, e is CryptoException ? 400 : 500, {
          'error': '$e',
        });
      } catch (_) {}
    }
  }

  Future<File> _partialFile(String sender, String asset) async {
    final hash = await Sha256().hash(utf8.encode('$sender|$asset'));
    final hex = hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return File('${_partial.path}/$hex.part');
  }

  Future<void> _upload(HttpRequest req, _Signed s) async {
    final m = s.meta;
    final sealer = s.sealer;
    final asset = m['asset'] as String? ?? '';
    final size = m['size'] as int? ?? -1;
    final offset = m['offset'] as int? ?? 0;
    if (sealer == null || asset.isEmpty || size < 0) {
      await req.drain<void>();
      return _reply(req, s, 400, {'error': 'missing metadata'});
    }
    if (await alreadyHave(s.sender, asset)) {
      await req.drain<void>();
      return _reply(req, s, 200, {'status': 'duplicate'});
    }
    final kind = switch (m['kind']) {
      'video' => 'video',
      'file' => 'file',
      _ => 'image',
    };
    if (kind != 'file' && !acceptsPhotos()) {
      await req.drain<void>();
      return _reply(req, s, 403, {'error': 'inbound'});
    }
    final name = _safeName(
      m['name'] as String? ?? '',
      fallback: kind == 'file' ? 'file' : 'photo.jpg',
    );

    // Resume: the partial file must hold exactly [offset] bytes.
    final part = await _partialFile(s.sender, asset);
    final held = await part.exists() ? await part.length() : 0;
    if (offset % kChunkSize != 0 || offset > held) {
      await req.drain<void>();
      return _reply(req, s, 409, {'offset': held - held % kChunkSize});
    }
    if (held != offset) {
      final raf = await part.open(mode: FileMode.append);
      await raf.truncate(offset);
      await raf.close();
    }

    final key = '${s.sender}|$asset';
    var received = offset;
    final sink = part.openWrite(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    try {
      await sink.addStream(
        sealer.openStream(req, firstIndex: offset ~/ kChunkSize).map((plain) {
          received += plain.length;
          onReceiving?.call(key, s.sender, name, received, size);
          return plain;
        }),
      );
    } on CryptoException {
      await sink.close();
      await part.delete();
      rethrow;
    } finally {
      try {
        await sink.close();
      } catch (_) {}
      onReceiving?.call(key, s.sender, name, received, size, done: true);
    }
    if (await part.length() != size) {
      return _reply(req, s, 400, {'error': 'incomplete upload'});
    }

    // Unique temp folder per upload keeps the original file name intact.
    final dir = await _tmp.createTemp('u');
    try {
      final file = await part.rename('${dir.path}/$name');
      final createdMs = m['created'] as int?;
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      await onFile(
        IncomingFile(
          senderId: s.sender,
          assetId: asset,
          name: name,
          kind: kind,
          created: createdMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(createdMs),
          location: lat == null || lng == null ? null : (lat, lng),
          dir: safeDir(m['dir'] as String? ?? ''),
          album: safeDir(m['album'] as String? ?? '').replaceAll('/', ' '),
          file: file,
        ),
      );
      await _reply(req, s, 200, {'status': 'saved'});
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  Future<void> _fixDates(HttpRequest req, _Signed s) async {
    final sealer = s.sealer;
    if (sealer == null) {
      await req.drain<void>();
      return _reply(req, s, 400, {'error': 'missing salt'});
    }
    final body = await sealer.openStream(req).expand((c) => c).toList();
    final list = jsonDecode(utf8.decode(body)) as List;
    final fixes = <DateFix>[
      for (final e in list.cast<Map<String, dynamic>>())
        (
          name: e['name'] as String,
          created: DateTime.fromMillisecondsSinceEpoch(e['created'] as int),
          location: e['lat'] == null
              ? null
              : ((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble()),
        ),
    ];
    final fixed = await onFixDates?.call(s.sender, fixes) ?? 0;
    await _reply(req, s, 200, {'fixed': fixed});
  }

  static final _unsafeChars = RegExp(r'[\x00-\x1f:*?"<>|]');

  static String _safeName(String raw, {required String fallback}) {
    final base = raw.split(RegExp(r'[/\\]')).last.trim();
    final cleaned = base.replaceAll(_unsafeChars, '_');
    if (cleaned.isEmpty || cleaned.startsWith('.')) {
      final ms = DateTime.now().millisecondsSinceEpoch;
      final dot = fallback.lastIndexOf('.');
      return dot < 0
          ? '${fallback}_$ms'
          : '${fallback.substring(0, dot)}_$ms${fallback.substring(dot)}';
    }
    return cleaned;
  }

  /// A relative folder path that can't escape the files folder: no `..`,
  /// no absolute paths, no hidden or empty segments.
  static String safeDir(String raw) => raw
      .split(RegExp(r'[/\\]'))
      .map((s) => s.trim().replaceAll(_unsafeChars, '_'))
      .where((s) => s.isNotEmpty && !s.startsWith('.'))
      .join('/');

  /// JSON reply, signed for paired callers so they can trust it.
  Future<void> _reply(
    HttpRequest req,
    _Signed? s,
    int status,
    Object body,
  ) async {
    final text = jsonEncode(body);
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    if (s != null) {
      req.response.headers.set(
        Hdr.sig,
        await s.keys.sign(signedResponse(s.nonce, status, text)),
      );
    }
    req.response.write(text);
    await req.response.close();
  }
}

/// IP addresses of this device, for showing "connect to me at ..." in the UI.
Future<List<String>> localAddresses() async {
  final out = <String>[];
  for (final iface in await NetworkInterface.list()) {
    for (final a in iface.addresses) {
      if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
        out.add(a.address);
      }
    }
  }
  return out;
}
