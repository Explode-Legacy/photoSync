import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'protocol.dart';

/// A file fully received and written to a temp path, ready to be saved.
class IncomingFile {
  IncomingFile({
    required this.senderId,
    required this.assetId,
    required this.name,
    required this.kind,
    required this.created,
    required this.location,
    required this.file,
  });

  final String senderId;
  final String assetId;
  final String name;

  /// `image` or `video`.
  final String kind;
  final DateTime? created;

  /// (latitude, longitude) from the sender's library, if it had one.
  final (double, double)? location;
  final File file;
}

/// HTTP server that accepts photos from the paired phone.
class ReceiveServer {
  ReceiveServer({
    required this.selfInfo,
    required this.currentKey,
    required this.alreadyHave,
    required this.onFile,
    this.tempRoot,
  });

  /// Where uploads are staged; defaults to the app's temp directory.
  final Directory? tempRoot;

  /// Returns this device's id/name/os for `GET /info`.
  final Map<String, dynamic> Function() selfInfo;
  final String Function() currentKey;
  final bool Function(String senderId, String assetId) alreadyHave;

  /// Saves the file to the gallery. The temp file is deleted afterwards.
  final Future<void> Function(IncomingFile file) onFile;

  HttpServer? _server;
  late Directory _tmp;

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    final root = tempRoot ?? await getTemporaryDirectory();
    _tmp = Directory('${root.path}/incoming');
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
    await _tmp.create(recursive: true);
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

  bool _authorized(HttpRequest r) => r.headers.value(Hdr.key) == currentKey();

  Future<void> _handle(HttpRequest req) async {
    try {
      switch ((req.method, req.uri.path)) {
        case ('GET', '/info'):
          await _json(req, 200, {
            ...selfInfo(),
            'v': kProtocolVersion,
            'paired': _authorized(req),
          });
        case ('GET', '/has'):
          if (!_authorized(req)) {
            return await _json(req, 401, {'error': 'pair'});
          }
          final sender = req.headers.value(Hdr.sender) ?? '';
          final asset = req.uri.queryParameters['asset'] ?? '';
          await _json(req, 200, {'has': alreadyHave(sender, asset)});
        case ('POST', '/upload'):
          await _upload(req);
        default:
          await _json(req, 404, {'error': 'not found'});
      }
    } catch (e) {
      try {
        await _json(req, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _upload(HttpRequest req) async {
    if (!_authorized(req)) {
      await req.drain<void>();
      return _json(req, 401, {'error': 'pair'});
    }
    final h = req.headers;
    final sender = h.value(Hdr.sender) ?? '';
    final asset = h.value(Hdr.assetId) ?? '';
    if (sender.isEmpty || asset.isEmpty) {
      await req.drain<void>();
      return _json(req, 400, {'error': 'missing ids'});
    }
    if (alreadyHave(sender, asset)) {
      await req.drain<void>();
      return _json(req, 200, {'status': 'duplicate'});
    }

    final name = _safeName(Uri.decodeComponent(h.value(Hdr.fileName) ?? ''));
    final createdMs = int.tryParse(h.value(Hdr.created) ?? '');
    final kind = h.value(Hdr.kind) == 'video' ? 'video' : 'image';
    final lat = double.tryParse(h.value(Hdr.lat) ?? '');
    final lng = double.tryParse(h.value(Hdr.lng) ?? '');

    // Unique temp folder per upload keeps the original file name intact.
    final dir = await _tmp.createTemp('u');
    final file = File('${dir.path}/$name');
    try {
      final sink = file.openWrite();
      await sink.addStream(req);
      await sink.close();

      final expected = req.contentLength;
      if (expected >= 0 && await file.length() != expected) {
        return await _json(req, 400, {'error': 'incomplete upload'});
      }
      await onFile(
        IncomingFile(
          senderId: sender,
          assetId: asset,
          name: name,
          kind: kind,
          created: createdMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(createdMs),
          location: lat == null || lng == null ? null : (lat, lng),
          file: file,
        ),
      );
      await _json(req, 200, {'status': 'saved'});
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  static String _safeName(String raw) {
    final base = raw.split(RegExp(r'[/\\]')).last.trim();
    final cleaned = base.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_');
    if (cleaned.isEmpty || cleaned.startsWith('.')) {
      return 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
    }
    return cleaned;
  }

  static Future<void> _json(HttpRequest req, int status, Object body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
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
