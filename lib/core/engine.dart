import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:pb_device/pb_device.dart';
import 'package:photo_manager/photo_manager.dart';

import 'client.dart';
import 'crypto.dart';
import 'discovery.dart';
import 'file_store.dart';
import 'folder_library.dart';
import 'history.dart';
import 'ledger.dart';
import 'media_library.dart';
import 'protocol.dart';
import 'scanner.dart';
import 'server.dart';
import 'settings.dart';

part 'engine_peers.dart';
part 'engine_receive.dart';
part 'engine_send.dart';

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
    this._receivedAs,
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

  /// `senderId|assetId` → the local asset id it was saved as.
  final MapLedger _receivedAs;

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

  /// Bumped when something is added to [ReceivedHistory], so the UI knows
  /// to re-read it.
  int historyVersion = 0;

  /// iPhone only: whether the app is on screen. Auto-sync never starts in
  /// the background on its own; background tasks start it explicitly.
  bool appInForeground = true;

  /// Where paired devices last reached us from, by device id.
  final Map<String, ({String host, int port, DateTime seen})> _contacts = {};

  /// Why auto-send last waited (Wi-Fi only, low battery), to log it once.
  String? _lastBlock;

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
      await MapLedger.open('received-as'),
    );
    await e._init();
    return e;
  }

  Future<void> _init() async {
    // Stretching the code takes a moment; start it before it's needed.
    unawaited(_keys());
    _client = PeerClient(
      selfId: settings.deviceId,
      keys: _keys,
      selfPort: () => port,
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
      keys: _keys,
      acceptsPhotos: () => settings.inbound,
      onReceiving: _onReceiving,
      onContact: _onContact,
      alreadyHave: _stillHave,
      onFile: _onIncoming,
      onFixDates: _onFixDates,
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
      'historyVersion': historyVersion,
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
        case 'fixDates':
          unawaited(
            fixDates(
              DateTime.fromMillisecondsSinceEpoch(cmd['sinceMs'] as int),
            ),
          );
        case 'resetSent':
          await _sent.clear();
          _addLog('info', 'Sent history cleared');
        case 'photoAccess':
          hasPhotoAccess = cmd['granted'] == true;
          await settings.setPhotoAccess(hasPhotoAccess);
          if (hasPhotoAccess) unawaited(_autoSync());
        case 'setAutoTo':
          await settings.setAutoTo(cmd['id'] as String, cmd['on'] as bool);
        case 'lifecycle':
          // The Mac keeps syncing with its window hidden or closed, and so
          // does the iPhone with "Keep running in background" on.
          if (mode == EngineMode.desktop) return;
          if (Platform.isIOS && settings.keepAlive) {
            appInForeground = true;
            return;
          }
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
