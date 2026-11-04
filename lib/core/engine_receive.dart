part of 'engine.dart';

/// Receiving: keys, what we hold, saving and history.
extension EngineReceiving on SyncEngine {
  // ---------------------------------------------------------------- receiving

  /// Keys for the current pairing code (derived once, then cached).
  /// The pairing code, stretched for SPAKE2 (once, then cached).
  Future<List<int>> _stretchedCode() => CodeSecret.stretch(settings.syncKey);

  void _onPairProblem(String id, String name, String reason) {
    if (_pairProblems[id] == reason) return;
    _pairProblems[id] = reason;
    _addLog('error', 'Couldn’t pair with $name: $reason');
  }

  Future<void> _onPaired(String id, String name, List<int> publicKey) async {
    _pairProblems.remove(id);
    await settings.trust(id, name, publicKey);
    _fingerprints[id] = await fingerprint(publicKey);
    _addLog('info', 'Paired with $name (${_fingerprints[id]})');
    _changed();
  }

  /// Unpairs every device (after the pairing code changes).
  Future<void> _forgetAll() async {
    await settings.forgetAll();
    _client.dropSessions();
    _server?.dropSessions();
    _fingerprints.clear();
    peers = {};
  }

  Future<void> _loadFingerprints() async {
    for (final e in settings.trustedDevices.entries) {
      _fingerprints[e.key] = await fingerprint(e.value.publicKey);
    }
  }

  Future<int> _onFixDates(String sender, List<DateFix> fixes) async {
    final fixed = await _library.repairDates(fixes);
    final from = peers[sender]?.info.name ?? 'another device';
    if (fixed > 0) _addLog('info', 'Fixed dates of $fixed photos from $from');
    return fixed;
  }

  /// Whether we still hold this asset from [sender]. False once it was
  /// deleted here, so the sender may send it again.
  Future<bool> _stillHave(String sender, String asset) async {
    final key = '$sender|$asset';
    if (!_received.contains(key)) return false;
    final local = _receivedAs[key];
    // Received before we kept the mapping: assume it's still here.
    if (local == null) return true;
    return _library.exists(local);
  }

  void _onReceiving(
    String key,
    String senderId,
    String name,
    int received,
    int total, {
    bool done = false,
  }) {
    if (done) {
      if (_incoming.remove(key) != null) _changed();
      return;
    }
    final (meter, info) = _incoming.putIfAbsent(
      key,
      () => (_SpeedMeter(), <String, dynamic>{}),
    );
    if (!meter.update(received, force: received == total)) return;
    info
      ..['current'] = name
      ..['from'] =
          peers[senderId]?.info.name ??
          _devices[senderId]?['name'] ??
          'another device'
      ..['frac'] = total > 0 ? received / total : 0.0
      ..['bytes'] = received
      ..['size'] = total > 0 ? total : 0
      ..['speed'] = meter.speed;
    _changed();
  }

  Future<void> _onIncoming(IncomingFile f) async {
    final from = peers[f.senderId]?.info.name ?? 'another device';
    if (f.kind == 'file') {
      final saved = await _files.save(f.file, dir: f.dir, name: f.name);
      receivedCount++;
      _addLog('received', 'Received ${saved.shown}');
      await _remember(f, from, saved.path);
      return;
    }
    if (!hasPhotoAccess) throw StateError('photo access denied');
    final localId = await _library.save(
      f.file,
      name: f.name,
      kind: f.kind,
      created: f.created,
      location: f.location,
      album: f.album,
    );
    // Record the import first so a library-change sync never echoes it back.
    await _imported.add(localId);
    await _received.add('${f.senderId}|${f.assetId}');
    await _receivedAs.set('${f.senderId}|${f.assetId}', localId);
    receivedCount++;
    _addLog('received', 'Received ${f.name}');
    // On the Mac a photo is a file in the photos folder, so it can be opened.
    await _remember(f, from, Platform.isMacOS ? localId : null);
  }

  Future<void> _remember(IncomingFile f, String from, String? path) async {
    try {
      await ReceivedHistory.add(
        Received(
          name: f.name,
          kind: f.kind,
          from: from,
          at: DateTime.now(),
          path: path,
        ),
      );
      historyVersion++;
    } catch (_) {}
  }
}

/// Smoothed transfer speed (bytes/s) from a running byte count.
class _SpeedMeter {
  final _clock = Stopwatch()..start();
  int _lastMs = 0;
  int _lastBytes = 0;
  double? speed;

  /// Records [bytes] so far. Returns false when called again too soon to be
  /// worth showing (under ~150 ms), unless [force].
  bool update(int bytes, {bool force = false}) {
    final ms = _clock.elapsedMilliseconds;
    if (ms - _lastMs < 150 && !force) return false;
    if (ms > _lastMs) {
      final now = (bytes - _lastBytes) * 1000 / (ms - _lastMs);
      speed = speed == null ? now : speed! * 0.7 + now * 0.3;
    }
    _lastMs = ms;
    _lastBytes = bytes;
    return true;
  }
}
