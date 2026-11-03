import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'client.dart';
import 'discovery.dart';
import 'file_store.dart';
import 'folder_library.dart';
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

  /// The Mac app. Always on while it runs, window or not.
  desktop,
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

  late final PhotoSource _library = Platform.isMacOS
      ? FolderLibrary(() => settings.photosFolder)
      : MediaLibrary();
  late final FileStore _files = FileStore(macRoot: () => settings.filesFolder);
  StreamSubscription<void>? _folderWatch;
  late final PeerClient _client;
  ReceiveServer? _server;
  late final LanDiscovery _discovery;

  /// Called (throttled) whenever [toState] would return something new.
  void Function()? onChange;

  bool hasPhotoAccess = false;

  /// Connected (paired and reachable) devices by id.
  Map<String, Peer> peers = {};
  Map<String, Map<String, dynamic>> _devices = {};

  /// Every address that answered the last probe → whether it's paired.
  Map<String, bool> _reachable = {};
  final Map<String, Map<String, dynamic>> _scanned = {};
  bool scanning = false;
  List<String> addresses = [];
  final List<Map<String, dynamic>> _log = [];

  bool syncing = false;
  Map<String, dynamic>? _progress;

  /// Uploads arriving right now, by sender|asset.
  final Map<String, (_SpeedMeter, Map<String, dynamic>)> _incoming = {};

  /// What's arriving right now: current (name), from, frac, bytes, size,
  /// speed. Usually one entry; more when several devices send at once.
  List<Map<String, dynamic>> get incoming => [
    for (final (_, info) in _incoming.values)
      if (info.isNotEmpty) info,
  ];
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

  String get os => Platform.isIOS
      ? 'ios'
      : Platform.isMacOS
      ? 'macos'
      : 'android';
  int get port => _server?.port ?? 0;

  bool get _autoAllowed =>
      settings.autoSend &&
      (mode == EngineMode.androidService ||
          mode == EngineMode.desktop ||
          appInForeground);

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
        'inbound': settings.inbound,
      },
      currentKey: () => settings.syncKey,
      acceptsPhotos: () => settings.inbound,
      onReceiving: _onReceiving,
      alreadyHave: (sender, asset) => _received.contains('$sender|$asset'),
      onFile: _onIncoming,
    );
    await _server!.start();
    _addLog('info', 'Ready on port $port');
    await _startDiscovery();
    _discovery.changes.listen((_) => _probe());

    if (Platform.isMacOS) {
      _watchFolder();
    } else {
      PhotoManager.addChangeCallback(_onLibraryChanged);
      await PhotoManager.startChangeNotify();
    }

    _probeTimer = Timer.periodic(const Duration(seconds: 8), (_) => _probe());
    unawaited(_probe());
  }

  Future<bool> _checkPhotoAccess() async {
    // The Mac sends a folder, not the Photos library.
    if (Platform.isMacOS) return true;
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
      'peers': [
        for (final p in peers.values)
          {
            'id': p.info.id,
            'name': p.info.name,
            'os': p.info.os,
            'address': p.address,
            'via': _routeLabel(p),
            'inbound': p.info.inbound,
          },
      ],
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
      'incoming': incoming,
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
        case 'sendFiles':
          unawaited(
            sendFiles(to: (cmd['to'] as List?)?.cast<String>(), [
              for (final f in cmd['files'] as List)
                (
                  path: (f as Map)['path'] as String,
                  name: f['name'] as String,
                  dir: f['dir'] as String? ?? '',
                ),
            ]),
          );
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
          peers = {};
          _addLog('info', 'Pairing code updated');
          await _probe();
        case 'newPairingCode':
          await settings.setSyncKey(generatePairingCode());
          peers = {};
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
          // Others learn about inbound from /info on their next probe.
          if (cmd['key'] == 'autoSend' && cmd['value'] == true) {
            unawaited(_autoSync());
          }
        case 'setSyncSince':
          await settings.setSyncSince(
            DateTime.fromMillisecondsSinceEpoch(cmd['ms'] as int),
          );
          unawaited(_autoSync());
        case 'setFolder':
          await settings.setFolder(cmd['key'] as String, cmd['path'] as String);
          if (cmd['key'] == 'photosFolder') {
            _watchFolder();
            unawaited(_autoSync());
          }
        case 'resetSent':
          await _sent.clear();
          _addLog('info', 'Sent history cleared');
        case 'photoAccess':
          hasPhotoAccess = cmd['granted'] == true;
          await settings.setPhotoAccess(hasPhotoAccess);
          if (hasPhotoAccess) unawaited(_autoSync());
        case 'lifecycle':
          // The Mac keeps syncing with its window hidden or closed.
          if (mode == EngineMode.desktop) return;
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
      if (joined.isNotEmpty) unawaited(_autoSync());
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
    if (_autoAllowed && peers.isNotEmpty) await syncNow();
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

  // ---------------------------------------------------------------- sending

  /// Devices that accept photos right now.
  List<Peer> get _photoTargets => [
    for (final p in peers.values)
      if (p.info.inbound) p,
  ];

  /// Sends everything new since [AppSettings.syncSince] (the Mac: everything
  /// in its photos folder) to every connected device that accepts photos,
  /// or exactly [assetIds] when given (manual pick; re-sends even if sent
  /// before). Stops early at [deadline] (background tasks have little time).
  Future<int> syncNow({List<String>? assetIds, DateTime? deadline}) async {
    if (syncing) {
      if (assetIds == null) _syncAgain = true;
      return 0;
    }
    if (peers.isEmpty) {
      _addLog('error', 'No other device found yet');
      return 0;
    }
    final targets = _photoTargets;
    if (targets.isEmpty) {
      if (assetIds != null) {
        _addLog('error', 'Connected devices have inbound turned off');
      }
      return 0;
    }
    if (!hasPhotoAccess) {
      _addLog('error', 'Photo access is off. Open the app to allow it.');
      return 0;
    }

    syncing = true;
    _cancel = false;
    _changed();
    final sentTo = <String, int>{};
    var sentNow = 0;
    try {
      final manual = assetIds != null;
      final candidates = manual
          ? await _library.byIds(assetIds)
          : await _library.pending(
              since: settings.syncSince,
              includeVideos: settings.includeVideos,
            );
      bool needs(Peer t, SourceItem a) =>
          manual || !_sent.contains('${t.info.id}|${a.id}');
      final queue = [
        for (final a in candidates)
          if (manual || !_imported.contains(a.id))
            if (targets.any((t) => needs(t, a))) a,
      ];
      if (queue.isEmpty) return 0;

      _addLog(
        'info',
        'Sending ${queue.length} to '
            '${targets.map((t) => t.info.name).join(', ')}',
      );
      hooks.onSyncStart?.call(queue.length);
      // Targets drop out of this run when they fail (offline, wrong code).
      final active = [...targets];
      for (var i = 0; i < queue.length && !_cancel && active.isNotEmpty; i++) {
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          _addLog('info', 'Out of background time, will continue later');
          break;
        }
        final item = queue[i];
        _setProgress(i, queue.length, item.title, 0);
        hooks.onProgress?.call(i, queue.length, item.title);
        // Exported once, then uploaded to each device that needs it.
        ExportedAsset? exported;
        for (final t in [...active]) {
          if (!needs(t, item)) continue;
          try {
            final sent = await _sendOne(
              t,
              item,
              () async => exported ??= await item.export(),
              i,
              queue.length,
            );
            if (sent) {
              sentNow++;
              sentTo.update(t.info.name, (n) => n + 1, ifAbsent: () => 1);
            }
          } on Exception catch (e) {
            if (_stopAfter(e, t)) active.remove(t);
          }
        }
        if (i % 10 == 9) await _library.releaseExports();
      }
      if (sentTo.isNotEmpty) {
        _addLog(
          'sent',
          'Sent ${[for (final e in sentTo.entries) '${e.value} to ${e.key}'].join(', ')}',
        );
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

  /// Logs a failed transfer to [target]. Returns true when the rest of the
  /// batch should skip it (wrong pairing code, inbound off, network gone);
  /// rethrows the unknown.
  bool _stopAfter(Exception e, Peer target) {
    final name = target.info.name;
    switch (e) {
      case TransferException():
        _addLog('error', '$name: ${e.message}');
        return e.unauthorized || e.rejected;
      case IOException():
        // Network dropped: skip it, the next probe/sync resumes from here.
        _addLog('error', 'Lost $name: ${e.runtimeType}');
        peers.remove(target.info.id);
        return true;
      case TimeoutException():
        _addLog('error', '$name timed out, will retry later');
        peers.remove(target.info.id);
        return true;
    }
    throw e;
  }

  /// Sends files the user picked (not photos) to the devices with ids in
  /// [to], or all connected ones. Each lands in the receiver's files folder
  /// under its [dir], so a picked folder arrives with its structure intact.
  /// Inbound doesn't apply: files are always sent on purpose.
  Future<int> sendFiles(
    List<({String path, String name, String dir})> files, {
    List<String>? to,
  }) async {
    if (files.isEmpty) return 0;
    if (syncing) {
      _addLog('error', 'Wait for the current transfer to finish');
      return 0;
    }
    final targets = [
      for (final p in peers.values)
        if (to == null || to.contains(p.info.id)) p,
    ];
    if (targets.isEmpty) {
      _addLog('error', 'No other device found yet');
      return 0;
    }

    syncing = true;
    _cancel = false;
    _changed();
    var sentNow = 0;
    final batch = _now();
    try {
      final names = targets.map((t) => t.info.name).join(', ');
      _addLog('info', 'Sending ${_countFiles(files.length)} to $names');
      hooks.onSyncStart?.call(files.length);
      final active = [...targets];
      for (var i = 0; i < files.length && !_cancel && active.isNotEmpty; i++) {
        final f = files[i];
        _setProgress(i, files.length, f.name, 0);
        hooks.onProgress?.call(i, files.length, f.name);
        final file = File(f.path);
        if (!await file.exists()) {
          _addLog('error', 'Could not read ${f.name}');
          continue;
        }
        var delivered = false;
        for (final t in [...active]) {
          try {
            await _client.upload(
              t,
              // Unique per send: picking the same file again sends it again.
              assetId: 'file:$batch:$i',
              file: file,
              name: f.name,
              kind: 'file',
              dir: f.dir,
              created: await file.lastModified(),
              onProgress: _progressFor(i, files.length, f.name, t),
            );
            delivered = true;
          } on Exception catch (e) {
            if (_stopAfter(e, t)) active.remove(t);
          }
        }
        if (delivered) sentNow++;
      }
      if (sentNow > 0) {
        _addLog('sent', 'Sent ${_countFiles(sentNow)} to $names');
      }
      if (_cancel) _addLog('info', 'Stopped');
    } catch (e) {
      _addLog('error', 'Sending files failed: $e');
    } finally {
      syncing = false;
      _progress = null;
      hooks.onSyncEnd?.call(sentNow);
      _changed();
    }
    return sentNow;
  }

  static String _countFiles(int n) => n == 1 ? '1 file' : '$n files';

  /// What's being sent right now, for the UI and the Android notification:
  /// item [done] of [total], [frac] of the current file, its [bytes] of
  /// [size], [speed] in bytes/s, and the device it's going [to].
  Map<String, dynamic>? get progress => _progress;

  void _setProgress(
    int done,
    int total,
    String name,
    double frac, {
    int bytes = 0,
    int size = 0,
    double? speed,
    String? to,
  }) {
    _progress = {
      'done': done,
      'total': total,
      'current': name,
      'frac': frac,
      'bytes': bytes,
      'size': size,
      'speed': ?speed,
      'to': ?to,
    };
    _changed();
  }

  /// Upload progress callback for one file to [target]: updates the
  /// percentage and a smoothed speed, a few times a second.
  void Function(int sent, int total) _progressFor(
    int i,
    int n,
    String name,
    Peer target,
  ) {
    final meter = _SpeedMeter();
    return (sent, total) {
      if (!meter.update(sent, force: sent >= total)) return;
      _setProgress(
        i,
        n,
        name,
        total == 0 ? 1 : sent / total,
        bytes: sent,
        size: total,
        speed: meter.speed,
        to: peers.length > 1 ? target.info.name : null,
      );
    };
  }

  /// Returns true when a file was actually transferred.
  Future<bool> _sendOne(
    Peer target,
    SourceItem item,
    Future<ExportedAsset?> Function() export,
    int i,
    int n,
  ) async {
    final ledgerKey = '${target.info.id}|${item.id}';
    if (await _client.has(target, item.id)) {
      await _sent.add(ledgerKey);
      return false;
    }
    final exported = await export();
    if (exported == null) {
      _addLog('error', 'Could not read ${item.title}');
      return false;
    }
    final status = await _client.upload(
      target,
      assetId: item.id,
      file: exported.file,
      name: exported.name,
      kind: exported.kind,
      created: item.created,
      location: item.location,
      onProgress: _progressFor(i, n, exported.name, target),
    );
    await _sent.add(ledgerKey);
    if (status == 'saved') sentCount++;
    return status == 'saved';
  }

  /// Entry point for iOS background tasks: find the devices, send what's
  /// new within [budget], and return how many photos went out.
  Future<int> runBackgroundSync(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    if (!settings.backgroundSync || !settings.autoSend) return 0;
    // Give Bonjour a moment; saved and last-known addresses work anyway.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _probe();
    if (peers.isEmpty) return 0;
    return syncNow(deadline: deadline);
  }

  // ---------------------------------------------------------------- receiving

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
    if (f.kind == 'file') {
      final saved = await _files.save(f.file, dir: f.dir, name: f.name);
      receivedCount++;
      _addLog('received', 'Received $saved');
      return;
    }
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
    await _folderWatch?.cancel();
    _emitTimer?.cancel();
    onChange = null;
    await _discovery.stop();
    await _server?.stop();
    _client.close();
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
