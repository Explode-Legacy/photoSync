import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import 'protocol.dart';

/// A PhotoBridge device seen on the local network via Bonjour/NSD.
class LanDevice {
  LanDevice({required this.id, required this.host, required this.port});

  final String id;
  final String host;
  final int port;
}

/// Advertises this device and finds others on the same Wi-Fi.
class LanDiscovery {
  LanDiscovery({required this.selfId});

  final String selfId;

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  /// Keyed by Bonjour service name, since "lost" events carry only the name.
  final Map<String, LanDevice> _devices = {};
  final _changes = StreamController<void>.broadcast();

  Iterable<LanDevice> get devices => _devices.values;
  Stream<void> get changes => _changes.stream;

  Future<void> start({
    required String name,
    required String os,
    required int port,
  }) async {
    await stop();
    final service = BonsoirService(
      // Suffix keeps names unique when both phones use the default name.
      name: '$name ${selfId.substring(0, 4)}',
      type: kServiceType,
      port: port,
      attributes: {'id': selfId, 'os': os},
    );
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.initialize();
    await _broadcast!.start();

    final discovery = _discovery = BonsoirDiscovery(type: kServiceType);
    await discovery.initialize();
    _sub = discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          if (service.attributes['id'] != selfId) {
            service.resolve(discovery.serviceResolver);
          }
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          _add(service);
        case BonsoirDiscoveryServiceLostEvent(:final service):
          if (_devices.remove(service.name) != null) _changes.add(null);
        default:
          break;
      }
    });
    await discovery.start();
  }

  void _add(BonsoirService s) {
    final id = s.attributes['id'];
    if (id == null || id == selfId) return;
    // Prefer IPv4: IPv6 link-local addresses need a zone id to be usable.
    final addrs = s.hostAddresses;
    final host =
        addrs.where((a) => !a.contains(':')).firstOrNull ??
        addrs.firstOrNull ??
        s.hostname;
    if (host == null) return;
    _devices[s.name] = LanDevice(id: id, host: host, port: s.port);
    _changes.add(null);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _discovery = null;
    _broadcast = null;
    _devices.clear();
  }
}
