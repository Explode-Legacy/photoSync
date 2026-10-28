/// Wire protocol shared by sender and receiver.
///
/// Every device runs a tiny HTTP server. The sender streams one file per
/// `POST /upload` request; the receiver saves it into its photo gallery.
library;

const kServiceType = '_photobridge._tcp';
const kDefaultPort = 53318;
const kProtocolVersion = 1;

/// Request headers. Lower-case because dart:io normalizes header names.
abstract final class Hdr {
  static const key = 'x-pb-key';
  static const sender = 'x-pb-sender';
  static const assetId = 'x-pb-asset';
  static const fileName = 'x-pb-name';
  static const created = 'x-pb-created';
  static const kind = 'x-pb-kind';

  /// Capture location from the sender's library, as decimal degrees.
  static const lat = 'x-pb-lat';
  static const lng = 'x-pb-lng';
}

/// What another device reports about itself at `GET /info`.
class PeerInfo {
  PeerInfo({
    required this.id,
    required this.name,
    required this.os,
    required this.paired,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Unknown',
    os: j['os'] as String? ?? '',
    paired: j['paired'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String os;

  /// True when the caller sent the right pairing code.
  final bool paired;
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
