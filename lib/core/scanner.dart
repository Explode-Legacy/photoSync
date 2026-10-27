import 'dart:async';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import 'client.dart';
import 'protocol.dart';

/// Largest range we sweep: a /20 (4094 hosts) takes ~10s. Bigger networks
/// get the /20 around our own address.
const _minMask = 0xFFFFF000;

/// Finds PhotoBridge devices by knocking on every address in this
/// device's Wi-Fi subnet. Slower than Bonjour, but works on office and
/// guest networks that block multicast.
Future<List<(String host, PeerInfo info)>> sweepSubnets(
  PeerClient client,
  List<String> localIps, {
  int port = kDefaultPort,
  int concurrency = 128,
}) async {
  final targets = <String>{};
  final ranges = await _subnets(localIps);
  for (final (ip, mask) in ranges) {
    targets.addAll(subnetHosts(ip, mask));
  }

  final found = <(String, PeerInfo)>[];
  final queue = targets.toList();
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final host = queue.removeLast();
      if (!await _portOpen(host, port)) continue;
      final info = await client.probe(host, port);
      if (info != null) found.add((host, info));
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  return found;
}

/// Every usable address in [ip]'s subnet except [ip] itself. The mask is
/// widened to at most a /20.
List<String> subnetHosts(String ip, int mask) {
  final m = (mask | _minMask) & 0xFFFFFFFF;
  final self = _toInt(ip);
  final network = self & m;
  final broadcast = network | (~m & 0xFFFFFFFF);
  return [
    for (var a = network + 1; a < broadcast; a++)
      if (a != self) _toIp(a),
  ];
}

/// Parses a dotted netmask such as 255.255.248.0.
int maskFromString(String m) => _toInt(m);

/// (ip, netmask) pairs to sweep. The Wi-Fi mask comes from the OS; other
/// private interfaces (e.g. Ethernet, hotspot) fall back to a /24.
Future<List<(String, int)>> _subnets(List<String> localIps) async {
  String? wifiIp;
  int? wifiMask;
  try {
    final info = NetworkInfo();
    wifiIp = await info.getWifiIP();
    final m = await info.getWifiSubmask();
    if (m != null && _isIpv4(m)) wifiMask = _toInt(m);
  } catch (_) {}

  final out = <(String, int)>[];
  for (final ip in {...localIps, ?wifiIp}.where(_isPrivateLan)) {
    final mask = ip == wifiIp && wifiMask != null ? wifiMask : 0xFFFFFF00;
    // At most a /20, so a /16 office network doesn't mean 65k probes.
    out.add((ip, mask));
  }
  return out;
}

Future<bool> _portOpen(String host, int port) async {
  try {
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: 500),
    );
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

bool _isIpv4(String s) {
  final p = s.split('.');
  return p.length == 4 &&
      p.every((x) {
        final n = int.tryParse(x);
        return n != null && n >= 0 && n <= 255;
      });
}

int _toInt(String ip) =>
    ip.split('.').map(int.parse).fold(0, (acc, b) => (acc << 8) | b);

String _toIp(int v) => [24, 16, 8, 0].map((s) => (v >> s) & 0xFF).join('.');

/// 10/8, 172.16/12 and 192.168/16. Tailscale's 100.64/10 is skipped: a
/// sweep there finds nothing, so Tailscale peers are added by name/IP.
bool _isPrivateLan(String ip) {
  if (!_isIpv4(ip)) return false;
  final p = ip.split('.').map(int.parse).toList();
  final a = p[0], b = p[1];
  return a == 10 || (a == 172 && b >= 16 && b < 32) || (a == 192 && b == 168);
}
