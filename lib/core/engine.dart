import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import 'client.dart';
import 'discovery.dart';
import 'ledger.dart';
import 'media_library.dart';
import 'protocol.dart';
import 'scanner.dart';
import 'server.dart';
import 'settings.dart';

/// Where the engine is running. It decides what the engine starts.
enum EngineMode {
  /// Inside the visible app (iPhone). Auto-sync only while on screen.
  foreground,

  /// Inside the Android foreground service. Always on.
  androidService,

  /// A short iOS background task: send new photos, then stop.
  iosBackground,
}

/// Optional callbacks a host uses to mirror sync progress elsewhere (the
/// iOS Live Activity, the Android notification).
class EngineHooks {
  const EngineHooks({this.onSyncStart, this.onProgress, this.onSyncEnd});

  final void Function(int total)? onSyncStart;
  final void Function(int done, int total, String name)? onProgress;
  final void Function(int sent)? onSyncEnd;
}

/// Server, discovery and send queue, independent of any UI.
///
/// The UI talks to it only through [handle] (commands) and [toState]
/// (a JSON snapshot), so the same engine can live in the app itself or in
/// a background isolate that outlives the app's screen.
class SyncEngine {
  SyncEngine._(
    this.mode,
    this.hooks,
    this.settings,
    this._sent,
    this._received,
    this._imported,
  );

  final EngineMode mode;
  final EngineHooks hooks;
  final AppSettings settings;

  /// `peerId|assetId` we've delivered.
  final IdLedger _sent;

  /// `senderId|assetId` we've received.
  final IdLedger _received;

  /// Local asset ids created by receiving; never sent back.
  final IdLedger _imported;

  final MediaLibrary _library = MediaLibrary();
  late final PeerClient _client;
  ReceiveServer? _server;
  late final LanDiscovery _discovery;

  /// Called (throttled) whenever [toState] would return something new.
  void Function()? onChange;

  bool hasPhotoAccess = false;
  Peer? peer;
  Map<String, Map<String, dynamic>> _devices = {};

  /// Every address that answered the last probe → whether it's paired.
  Map<String, bool> _reachable = {};
  final Map<String, Map<String, dynamic>> _scanned = {};
  bool scanning = false;
  List<String> addresses = [];
  final List<Map<String, dynamic>> _log = [];

  bool syncing = false;
  Map<String, dynamic>? _progress;
  int sentCount = 0;
  int receivedCount = 0;

  /// iPhone only: whether the app is on screen. Auto-sync never starts in
  /// the background on its own; background tasks start it explicitly.
  bool appInForeground = true;

  bool _cancel = false;
  bool _syncAgain = false;
  bool _probing = false;
  Timer? _probeTimer;
  Timer? _changeDebounce;
  Timer? _emitTimer;

  String get os => Platform.isIOS ? 'ios' : 'android';
  int get port => _server?.port ?? 0;

  bool get _autoAllowed =>
      settings.autoSend &&
      (mode == EngineMode.androidService || appInForeground);

  static Future<SyncEngine> create(
    EngineMode mode, {
    EngineHooks hooks = const EngineHooks(),
  }) async {
    final e = SyncEngine._(
      mode,
      hooks,
      await AppSettings.load(),
      await IdLedger.open('sent'),
      await IdLedger.open('received'),
      await IdLedger.open('imported'),
    );
    await e._init();
    return e;
  }

  Future<void> _init() async {
    _client = PeerClient(
      selfId: settings.deviceId,
      key: () => settings.syncKey,
    );
    _discovery = LanDiscovery(selfId: settings.deviceId);

    // The service isolate has no Activity to show a permission prompt, so
    // the UI asks and tells us (see the `photoAccess` command).
    hasPhotoAccess = await _checkPhotoAccess();
    addresses = await localAddresses();

    if (mode == EngineMode.iosBackground) {
      // Short-lived: no server and no timers, just discovery for a moment.
      await _startDiscovery();
      return;
    }

    _server = ReceiveServer(
      selfInfo: () => {
        'id': settings.deviceId,
        'name': settings.deviceName,
        'os': os,
      },
      currentKey: () => settings.syncKey,
      alreadyHave: (sender, asset) => _received.contains('$sender|$asset'),
      onFile: _onIncoming,
    );
    await _server!.start();
    _addLog('info', 'Ready on port $port');
    await _startDiscovery();
    _discovery.changes.listen((_) => _probe());

    PhotoManager.addChangeCallback(_onLibraryChanged);
    await PhotoManager.startChangeNotify();

    _probeTimer = Timer.periodic(const Duration(seconds: 8), (_) => _probe());
    unawaited(_probe());
  }

  Future<bool> _checkPhotoAccess() async {
    try {
      if (mode == EngineMode.androidService) {
        // Permission APIs need an Activity, which a service doesn't have.
        // Trust what the UI last reported (see the `photoAccess` command).
        await PhotoManager.setIgnorePermissionCheck(true);
        return settings.photoAccess;
      }
      if (mode == EngineMode.iosBackground) {
        final s = await PhotoManager.getPermissionState(
          requestOption: const PermissionRequestOption(),
        );
        return s.hasAccess;
      }
      return await _library.requestPermission();
    } catch (_) {
      return false;
    }
  }

  Future<void> _startDiscovery() async {
    try {
      await _discovery.start(name: settings.deviceName, os: os, port: port);
    } catch (e) {
      _addLog('error', 'Wi-Fi discovery unavailable: $e');
    }
  }

  // ---------------------------------------------------------------- state

  Map<String, dynamic> toState() {
    final saved = {for (final p in settings.savedPeers) p.address};
    final devices = {..._devices, ..._scanned};
    return {
      'settings': settings.toJson(),
      'hasPhotoAccess': hasPhotoAccess,
      'peer': peer == null
          ? null
          : {
              'id': peer!.info.id,
              'name': peer!.info.name,
              'os': peer!.info.os,
              'address': peer!.address,
              'via': _routeLabel(peer!),
            },
      'devices': [
        for (final d in devices.values)
          {...d, 'saved': saved.contains(d['address'])},
      ],
      'reachable': _reachable,
      'scanning': scanning,
      'addresses': addresses,
      'port': port,
      'log': _log,
      'syncing': syncing,
      'progress': _progress,
      'sentCount': sentCount,
      'receivedCount': receivedCount,
      'mode': mode.name,
    };
  }

  /// Human name for how we reach [p]: a saved label, Wi-Fi or Tailscale.
  String _routeLabel(Peer p) {
    for (final s in settings.savedPeers) {
      final parsed = parseAddress(s.address);
      if (parsed != null && parsed.$1 == p.host && parsed.$2 == p.port) {
        return s.label;
      }
    }
    if (_isTailscale(p.host)) return 'Tailscale';
    return 'Wi-Fi';
  }

  static bool _isTailscale(String host) {
    if (host.endsWith('.ts.net') || host.startsWith('fd7a:115c:a1e0')) {
      return true;
    }
    final parts = host.split('.').map(int.tryParse).toList();
    // 100.64.0.0/10 (CGNAT range Tailscale uses).
    return parts.length == 4 &&
        parts[0] == 100 &&
        (parts[1] ?? 0) >= 64 &&
        (parts[1] ?? 0) < 128;
  }

  void _changed() {
    if (onChange == null) return;
    _emitTimer ??= Timer(const Duration(milliseconds: 150), () {
      _emitTimer = null;
      onChange?.call();
    });
  }

  void _addLog(String kind, String text) {
    // Also to the system log, readable over USB for debugging.
    debugPrint('[PhotoBridge ${mode.name}] $kind: $text');
    _log.insert(0, {'k': kind, 't': text, 'ms': _now()});
    if (_log.length > 100) _log.removeLast();
    _changed();
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // ---------------------------------------------------------------- commands

  Future<void> _commands = Future.value();

  /// Applies a command from the UI, one at a time and in order (so e.g.
  /// two edits to the saved list can't overwrite each other).
  Future<void> handle(Map<String, dynamic> cmd) {
    return _commands = _commands.then((_) => _handle(cmd));
  }

  Future<void> _handle(Map<String, dynamic> cmd) async {
    try {
      switch (cmd['cmd']) {
        case 'hello':
          onChange?.call();
        case 'sync':
          final ids = (cmd['assetIds'] as List?)?.cast<String>();
          unawaited(syncNow(assetIds: ids));
        case 'cancel':
          _cancel = true;
          _syncAgain = false;
        case 'refresh':
          await refresh();
        case 'scan':
          unawaited(scan());
        case 'setPairingCode':
          final code = normalizePairingCode(cmd['code'] as String);
          if (code.length < 6) throw ArgumentError('Code is too short');
          await settings.setSyncKey(code);
          peer = null;
          _addLog('info', 'Pairing code updated');
          await _probe();
        case 'newPairingCode':
          await settings.setSyncKey(generatePairingCode());
          peer = null;
          await _probe();
        case 'setDeviceName':
          final name = (cmd['name'] as String).trim();
          if (name.isNotEmpty) {
            await settings.setDeviceName(name);
            await _startDiscovery();
          }
        case 'savePeer':
          await _savePeer(
            cmd['label'] as String,
            cmd['address'] as String,
            replacing: cmd['replacing'] as String?,
          );
        case 'removePeer':
          await settings.setSavedPeers([
            for (final p in settings.savedPeers)
              if (p.address != cmd['address']) p,
          ]);
          unawaited(_probe());
        case 'setToggle':
          await settings.setToggle(cmd['key'] as String, cmd['value'] as bool);
          if (cmd['key'] == 'autoSend' && cmd['value'] == true) {
            unawaited(_autoSync());
          }
        case 'setSyncSince':
          await settings.setSyncSince(
            DateTime.fromMillisecondsSinceEpoch(cmd['ms'] as int),
          );
          unawaited(_autoSync());
        case 'resetSent':
          await _sent.clear();
          _addLog('info', 'Sent history cleared');
        case 'photoAccess':
          hasPhotoAccess = cmd['granted'] == true;
          await settings.setPhotoAccess(hasPhotoAccess);
          if (hasPhotoAccess) unawaited(_autoSync());
        case 'lifecycle':
          appInForeground = cmd['foreground'] == true;
          if (appInForeground) await onResumed();
      }
    } catch (e) {
      _addLog('error', '$e');
    }
    _changed();
  }

  /// Adds or updates a saved address. [replacing] is the entry's previous
  /// address when it's being edited, so the edit stays in place.
  Future<void> _savePeer(
    String label,
    String address, {
    String? replacing,
  }) async {
    final a = address.trim();
    if (parseAddress(a) == null) throw ArgumentError('Invalid address: $a');
    final entry = SavedPeer(label.trim().isEmpty ? a : label.trim(), a);
    final peers = <SavedPeer>[];
    var placed = false;
    for (final p in settings.savedPeers) {
      if (p.address == (replacing ?? a) || p.address == a) {
        if (!placed) peers.add(entry);
        placed = true;
      } else {
        peers.add(p);
      }
    }
    if (!placed) peers.add(entry);
    await settings.setSavedPeers(peers);
    _addLog('info', 'Saved ${entry.label} (${entry.address})');
    _changed();
    unawaited(_probe());
  }

  // ---------------------------------------------------------------- peers

  /// Probes every known address at once and picks the first paired device,
  /// preferring Wi-Fi discovery, then saved addresses, then the last one.
  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    try {
      final candidates = <(String, int)>{
        for (final d in _discovery.devices) (d.host, d.port),
        for (final p in settings.savedPeers) ?parseAddress(p.address),
        ?parseAddress(settings.lastPeer),
        if (peer case final p?) (p.host, p.port),
      }.toList();

      final results = await Future.wait(
        candidates.map((c) => _client.probe(c.$1, c.$2)),
      );

      Peer? found;
      final devices = <String, Map<String, dynamic>>{};
      final reachable = <String, bool>{};
      for (var i = 0; i < candidates.length; i++) {
        final info = results[i];
        if (info == null || info.id == settings.deviceId) continue;
        final (host, p) = candidates[i];
        final candidate = Peer(info, host, p);
        found ??= info.paired ? candidate : null;
        devices.putIfAbsent(info.id, () => _deviceJson(candidate));
        reachable[candidate.address] = info.paired;
      }

      final wasOnline = peer != null;
      final changed =
          found?.address != peer?.address ||
          devices.length != _devices.length ||
          reachable.length != _reachable.length;
      peer = found;
      _devices = devices;
      _reachable = reachable;
      if (found != null) {
        if (settings.lastPeer != found.address) {
          await settings.setLastPeer(found.address);
        }
        if (!wasOnline) {
          _addLog('info', 'Connected to ${found.info.name}');
          unawaited(_autoSync());
        }
      } else if (wasOnline) {
        _addLog('info', 'Other phone went offline');
      }
      if (changed) _changed();
    } finally {
      _probing = false;
    }
  }

  static Map<String, dynamic> _deviceJson(Peer p) => {
    'id': p.info.id,
    'name': p.info.name,
    'os': p.info.os,
    'address': p.address,
    'paired': p.info.paired,
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
    if (_autoAllowed && peer != null) await syncNow();
  }

  void _onLibraryChanged(MethodCall _) {
    if (!_autoAllowed) return;
    // Bursts of changes (e.g. saving 50 photos from WhatsApp) → one sync.
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(seconds: 3), _autoSync);
  }

  // ---------------------------------------------------------------- sending

  /// Sends everything new since [AppSettings.syncSince], or exactly
  /// [assetIds] when given (manual pick; re-sends even if sent before).
  /// Stops early at [deadline] (background tasks have little time).
  Future<int> syncNow({List<String>? assetIds, DateTime? deadline}) async {
    if (syncing) {
      if (assetIds == null) _syncAgain = true;
      return 0;
    }
    final target = peer;
    if (target == null) {
      _addLog('error', 'Other phone not found yet');
      return 0;
    }
    if (!hasPhotoAccess) {
      _addLog('error', 'Photo access is off. Open the app to allow it.');
      return 0;
    }

    syncing = true;
    _cancel = false;
    _changed();
    var sentNow = 0;
    try {
      final manual = assetIds != null;
      final List<AssetEntity> candidates;
      if (manual) {
        candidates = [for (final id in assetIds) ?await AssetEntity.fromId(id)];
      } else {
        candidates = await _library.assetsSince(
          settings.syncSince,
          includeVideos: settings.includeVideos,
        );
      }
      final queue = candidates
          .where(
            (a) =>
                manual ||
                (!_imported.contains(a.id) &&
                    !_sent.contains('${target.info.id}|${a.id}')),
          )
          .toList();
      if (queue.isEmpty) return 0;

      _addLog('info', 'Sending ${queue.length} to ${target.info.name}');
      hooks.onSyncStart?.call(queue.length);
      for (var i = 0; i < queue.length && !_cancel; i++) {
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          _addLog('info', 'Out of background time, will continue later');
          break;
        }
        final asset = queue[i];
        _setProgress(i, queue.length, asset.title ?? 'item ${i + 1}', 0);
        hooks.onProgress?.call(i, queue.length, asset.title ?? '');
        try {
          if (await _sendOne(target, asset, i, queue.length)) sentNow++;
        } on TransferException catch (e) {
          _addLog('error', e.message);
          if (e.unauthorized) break;
        } on IOException catch (e) {
          // Network dropped: stop, the next probe/sync resumes from here.
          _addLog('error', 'Connection lost: ${e.runtimeType}');
          peer = null;
          break;
        } on TimeoutException {
          _addLog('error', 'Timed out, will retry later');
          peer = null;
          break;
        }
        if (i % 10 == 9) await _library.releaseExports();
      }
      if (sentNow > 0) {
        _addLog('sent', 'Sent $sentNow to ${target.info.name}');
      }
      if (_cancel) _addLog('info', 'Stopped');
    } catch (e) {
      _addLog('error', 'Sync failed: $e');
    } finally {
      await _library.releaseExports();
      syncing = false;
      _progress = null;
      hooks.onSyncEnd?.call(sentNow);
      _changed();
    }
    if (_syncAgain && !_cancel) {
      _syncAgain = false;
      unawaited(syncNow(deadline: deadline));
    }
    return sentNow;
  }

  void _setProgress(int done, int total, String name, double frac) {
    _progress = {'done': done, 'total': total, 'current': name, 'frac': frac};
    _changed();
  }

  /// Photos says 0,0 when an asset has no location.
  static (double, double)? _locationOf(AssetEntity asset) {
    final lat = asset.latitude, lng = asset.longitude;
    if (lat == null || lng == null || (lat == 0 && lng == 0)) return null;
    return (lat, lng);
  }

  /// Returns true when a file was actually transferred.
  Future<bool> _sendOne(Peer target, AssetEntity asset, int i, int n) async {
    final ledgerKey = '${target.info.id}|${asset.id}';
    if (await _client.has(target, asset.id)) {
      await _sent.add(ledgerKey);
      return false;
    }
    final exported = await _library.export(asset);
    if (exported == null) {
      _addLog('error', 'Could not read ${asset.title ?? asset.id}');
      return false;
    }
    var lastNotify = 0;
    final status = await _client.upload(
      target,
      assetId: asset.id,
      file: exported.file,
      name: exported.name,
      kind: exported.kind,
      created: asset.createDateTime,
      location: _locationOf(asset),
      onProgress: (sent, total) {
        final now = _now();
        if (now - lastNotify < 150) return;
        lastNotify = now;
        _setProgress(i, n, exported.name, total == 0 ? 1 : sent / total);
      },
    );
    await _sent.add(ledgerKey);
    if (status == 'saved') sentCount++;
    return status == 'saved';
  }

  /// Entry point for iOS background tasks: find the peer, send what's new
  /// within [budget], and return how many photos went out.
  Future<int> runBackgroundSync(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    if (!settings.backgroundSync || !settings.autoSend) return 0;
    // Give Bonjour a moment; saved and last-known addresses work anyway.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _probe();
    if (peer == null) return 0;
    return syncNow(deadline: deadline);
  }

  // ---------------------------------------------------------------- receiving

  Future<void> _onIncoming(IncomingFile f) async {
    if (!hasPhotoAccess) throw StateError('photo access denied');
    final localId = await _library.save(
      f.file,
      name: f.name,
      kind: f.kind,
      created: f.created,
      location: f.location,
    );
    // Record the import first so a library-change sync never echoes it back.
    await _imported.add(localId);
    await _received.add('${f.senderId}|${f.assetId}');
    receivedCount++;
    _addLog('received', 'Received ${f.name}');
  }

  Future<void> dispose() async {
    _probeTimer?.cancel();
    _changeDebounce?.cancel();
    _emitTimer?.cancel();
    onChange = null;
    await _discovery.stop();
    await _server?.stop();
    _client.close();
  }
}
