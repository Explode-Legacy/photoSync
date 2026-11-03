part of 'engine.dart';

/// Finding and keeping track of the other devices.
extension EnginePeers on SyncEngine {
  // ---------------------------------------------------------------- peers

  /// Probes every known address at once and keeps every paired device, each
  /// at the first address that answered (Wi-Fi discovery, then saved
  /// addresses, then the last ones that worked).
  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    try {
      final candidates = <(String, int)>{
        for (final d in _discovery.devices) (d.host, d.port),
        for (final p in settings.savedPeers) ?parseAddress(p.address),
        ?parseAddress(settings.lastPeer),
        for (final p in peers.values) (p.host, p.port),
        for (final c in _contacts.values)
          if (DateTime.now().difference(c.seen) < _contactTtl) (c.host, c.port),
      }.toList();

      final results = await Future.wait(
        candidates.map((c) => _client.probe(c.$1, c.$2)),
      );

      final found = <String, Peer>{};
      final devices = <String, Map<String, dynamic>>{};
      final reachable = <String, bool>{};
      for (var i = 0; i < candidates.length; i++) {
        final info = results[i];
        if (info == null || info.id == settings.deviceId) continue;
        final (host, p) = candidates[i];
        final candidate = Peer(info, host, p);
        if (info.paired) found.putIfAbsent(info.id, () => candidate);
        devices.putIfAbsent(info.id, () => _deviceJson(candidate));
        reachable[candidate.address] = info.paired;
      }

      final joined = [
        for (final p in found.values)
          if (!peers.containsKey(p.info.id)) p,
      ];
      final left = [
        for (final p in peers.values)
          if (!found.containsKey(p.info.id)) p,
      ];
      final changed =
          joined.isNotEmpty ||
          left.isNotEmpty ||
          [
                for (final p in found.values)
                  (p.address, p.info.inbound, p.info.name),
              ].join() !=
              [
                for (final p in peers.values)
                  (p.address, p.info.inbound, p.info.name),
              ].join() ||
          devices.length != _devices.length ||
          reachable.length != _reachable.length;
      peers = found;
      _devices = devices;
      _reachable = reachable;
      if (found.values.firstOrNull case final first?) {
        if (settings.lastPeer != first.address) {
          await settings.setLastPeer(first.address);
        }
      }
      for (final p in joined) {
        _addLog('info', 'Connected to ${p.info.name}');
      }
      for (final p in left) {
        _addLog('info', '${p.info.name} went offline');
      }
      // Also retry while waiting for Wi-Fi or a charger.
      if (joined.isNotEmpty || (_lastBlock != null && found.isNotEmpty)) {
        unawaited(_autoSync());
      }
      if (changed) _changed();
    } finally {
      _probing = false;
    }
  }

  static const _contactTtl = Duration(minutes: 15);

  void _onContact(String id, String host, int port) {
    _contacts[id] = (host: host, port: port, seen: DateTime.now());
    // A device we don't see yet just reached us: try connecting back now.
    if (!peers.containsKey(id)) unawaited(_probe());
  }

  static Map<String, dynamic> _deviceJson(Peer p) => {
    'id': p.info.id,
    'name': p.info.name,
    'os': p.info.os,
    'address': p.address,
    'paired': p.info.paired,
    'outdated': p.info.version < kProtocolVersion,
  };

  /// Bonjour results plus a direct sweep of the Wi-Fi subnet.
  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    _scanned.clear();
    _changed();
    try {
      addresses = await localAddresses();
      await _probe();
      final hits = await sweepSubnets(_client, addresses);
      for (final (host, info) in hits) {
        if (info.id == settings.deviceId) continue;
        _scanned[info.id] = _deviceJson(Peer(info, host, kDefaultPort));
      }
    } finally {
      scanning = false;
      _changed();
    }
  }

  Future<void> refresh() async {
    await settings.reload();
    addresses = await localAddresses();
    await _probe();
    _changed();
  }

  Future<void> onResumed() async {
    await refresh();
    unawaited(_autoSync());
  }

  Future<void> _autoSync() async {
    if (!_autoAllowed || peers.isEmpty) return;
    final block = await _autoBlocked();
    // Say so once, not on every check.
    if (block != _lastBlock) {
      _lastBlock = block;
      if (block != null) _addLog('info', block);
    }
    if (block == null) await syncNow(auto: true);
  }

  void _onLibraryChanged([Object? _]) {
    if (!_autoAllowed) return;
    // Bursts of changes (e.g. saving 50 photos from WhatsApp) → one sync.
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(seconds: 3), _autoSync);
  }

  /// Mac: follow the photos folder (again, when it's changed in Settings).
  void _watchFolder() {
    _folderWatch?.cancel();
    final library = _library;
    if (library is! FolderLibrary) return;
    try {
      _folderWatch = library.watch().listen(
        _onLibraryChanged,
        onError: (Object e) => _addLog('error', 'Watching folder: $e'),
      );
    } catch (e) {
      _addLog('error', 'Watching folder: $e');
    }
  }
}
