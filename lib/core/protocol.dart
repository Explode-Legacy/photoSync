/// Wire protocol shared by sender and receiver.
///
/// Every device runs a tiny HTTP server. Devices pair once with the code
/// (SPAKE2) and then talk in short-lived sessions keyed from their identity
/// keys (Noise KK); see identity.dart. Requests are signed with the session
/// key and everything private (file contents, names, dates, locations,
/// folders) is encrypted end to end; see crypto.dart.
///
/// - `GET /info`: who is this (name, kind, identity key)? Public.
/// - `POST /pair`, `POST /pair/confirm`: SPAKE2 with the pairing code.
/// - `POST /session`: a new session with a device that's already paired.
/// - `GET /status`: does the receiver have this asset, and how much of an
///   interrupted upload does it hold?
/// - `POST /upload`: one photo, video or file, encrypted in chunks;
///   resumes at the offset `/status` reported.
/// - `POST /fixdates`: corrected capture dates for photos sent earlier.
library;

const kServiceType = '_photobridge._tcp';
const kDefaultPort = 53318;

/// 3: device identity keys, SPAKE2 pairing and forward-secret sessions.
/// Devices on older versions can't pair.
const kProtocolVersion = 3;

/// Request and response headers. Lower-case: dart:io normalizes them.
abstract final class Hdr {
  static const sender = 'x-pb-sender';

  /// Session id from `POST /session`; its keys sign and encrypt the request.
  static const session = 'x-pb-session';

  /// The caller's own server port, so the receiver can connect back to it
  /// at the address the request came from.
  static const port = 'x-pb-port';

  /// Signing: milliseconds since epoch, a one-time random value, and the
  /// signature over [signedRequest]. Requests older than 5 minutes or with
  /// a reused nonce are refused.
  static const ts = 'x-pb-ts';
  static const nonce = 'x-pb-nonce';
  static const auth = 'x-pb-auth';

  /// Random salt for this request's encryption key, and the encrypted JSON
  /// metadata (asset id, name, dates, ...).
  static const salt = 'x-pb-salt';
  static const meta = 'x-pb-meta';

  /// Reply signature over [signedResponse].
  static const sig = 'x-pb-sig';
}

/// Path and query of [uri], as both ends see it.
String requestTarget(Uri uri) =>
    uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

/// The exact text a request signature covers.
String signedRequest({
  required String method,
  required String target,
  required String ts,
  required String nonce,
  required String sender,
  required String salt,
  required String meta,
}) => ['pb2', method, target, ts, nonce, sender, salt, meta].join('\n');

/// The exact text a reply signature covers: it's bound to the request's
/// nonce, so an old reply can't be replayed.
String signedResponse(String nonce, int status, String body) =>
    ['pb2-reply', nonce, '$status', body].join('\n');

/// What another device reports about itself at `GET /info`.
class PeerInfo {
  PeerInfo({
    required this.id,
    required this.name,
    required this.os,
    required this.paired,
    this.inbound = true,
    this.version = 1,
    this.publicKey = '',
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Unknown',
    os: j['os'] as String? ?? '',
    paired: j['paired'] as bool? ?? false,
    inbound: j['inbound'] as bool? ?? true,
    version: j['v'] as int? ?? 1,
    publicKey: j['pub'] as String? ?? '',
  );

  /// Copy with [paired] decided by the reply signature, not the body.
  PeerInfo withPaired(bool v) => PeerInfo(
    id: id,
    name: name,
    os: os,
    paired: v,
    inbound: inbound,
    version: version,
    publicKey: publicKey,
  );

  final String id;
  final String name;
  final String os;

  /// True when the caller sent the right pairing code.
  final bool paired;

  /// Whether it accepts photos (its "Allow inbound" setting). Files are
  /// always accepted.
  final bool inbound;

  /// [kProtocolVersion] it speaks; older ones need updating to pair.
  final int version;

  /// Its identity key (base64url), as it claims; trusted only after pairing.
  final String publicKey;
}

/// A device we can talk to, with the address that worked.
class Peer {
  Peer(this.info, this.host, this.port);

  final PeerInfo info;
  final String host;
  final int port;

  String get address => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// Parses "100.101.102.103", "100.101.102.103:53318" or "[fd7a::1]:53318".
(String, int)? parseAddress(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end < 0) return null;
    final host = s.substring(1, end);
    final rest = s.substring(end + 1);
    final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
    return (host, port ?? kDefaultPort);
  }
  final colons = ':'.allMatches(s).length;
  if (colons == 1) {
    final i = s.indexOf(':');
    final port = int.tryParse(s.substring(i + 1));
    if (port == null) return null;
    return (s.substring(0, i), port);
  }
  // Bare IPv4/hostname, or a bare IPv6 address without a port.
  return (s, kDefaultPort);
}
