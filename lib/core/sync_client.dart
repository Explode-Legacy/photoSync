import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'android_service.dart';
import 'engine.dart';
import 'ios_background.dart';
import 'mac_bridge.dart';
import 'settings.dart';

/// Read-only view of an engine snapshot ([SyncEngine.toState]).
class EngineState {
  EngineState(this.raw);

  final Map<String, dynamic> raw;

  Map<String, dynamic> get _s => (raw['settings'] as Map).cast();

  String get deviceName => _s['deviceName'] as String? ?? '';
  String get pairingCode => _s['syncKey'] as String? ?? '';
  bool get autoSend => _s['autoSend'] == true;
  bool get includeVideos => _s['includeVideos'] == true;
  bool get backgroundSync => _s['backgroundSync'] == true;
  DateTime get syncSince =>
      DateTime.fromMillisecondsSinceEpoch(_s['syncSince'] as int? ?? 0);
  List<SavedPeer> get savedPeers => [
    for (final p in (_s['savedPeers'] as List? ?? []))
      SavedPeer.fromJson((p as Map).cast()),
  ];

  bool get inbound => _s['inbound'] != false;
  bool get wifiOnly => _s['wifiOnly'] == true;
  bool get lowBatteryPause => _s['lowBatteryPause'] != false;
  bool get keepAlive => _s['keepAlive'] == true;
  bool get menuBarOnly => _s['menuBarOnly'] == true;
  Set<String> get noAutoTo => {
    ...(_s['noAutoTo'] as List? ?? []).cast<String>(),
  };
  String get photosFolder => _s['photosFolder'] as String? ?? '';
  String get filesFolder => _s['filesFolder'] as String? ?? '';

  bool get hasPhotoAccess => raw['hasPhotoAccess'] == true;

  /// Every connected device: id, name, os, address, via, inbound.
  List<Map<String, dynamic>> get peers => [
    for (final p in (raw['peers'] as List? ?? [])) (p as Map).cast(),
  ];

  /// First connected device, or null when none.
  Map<String, dynamic>? get peer => peers.firstOrNull;
  List<Map<String, dynamic>> get devices => [
    for (final d in (raw['devices'] as List? ?? [])) (d as Map).cast(),
  ];
  Map<String, bool> get reachable =>
      (raw['reachable'] as Map? ?? {}).cast<String, bool>();
  bool get scanning => raw['scanning'] == true;
  List<String> get addresses =>
      (raw['addresses'] as List? ?? []).cast<String>();
  int get port => raw['port'] as int? ?? 0;
  List<Map<String, dynamic>> get log => [
    for (final e in (raw['log'] as List? ?? [])) (e as Map).cast(),
  ];
  bool get syncing => raw['syncing'] == true;
  Map<String, dynamic>? get progress => (raw['progress'] as Map?)?.cast();

  /// Files arriving right now (see SyncEngine.incoming).
  List<Map<String, dynamic>> get incoming => [
    for (final e in (raw['incoming'] as List? ?? [])) (e as Map).cast(),
  ];
  int get sentCount => raw['sentCount'] as int? ?? 0;
  int get receivedCount => raw['receivedCount'] as int? ?? 0;
  int get historyVersion => raw['historyVersion'] as int? ?? 0;
}

/// What the UI uses to observe and control the engine, wherever it runs.
abstract class SyncClient extends ChangeNotifier {
  EngineState? get state;

  void send(String cmd, [Map<String, dynamic> args = const {}]);

  /// Platform-appropriate client: on Android the engine lives in a
  /// foreground service; on iPhone and the Mac it runs in the app.
  static Future<SyncClient> create() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return ServiceSyncClient.start();
    }
    return LocalSyncClient.start();
  }
}

/// Engine in this isolate (iPhone, Mac).
class LocalSyncClient extends SyncClient {
  LocalSyncClient._(this._engine) {
    _engine.onChange = _refresh;
    _refresh();
  }

  final SyncEngine _engine;
  EngineState? _state;

  static Future<LocalSyncClient> start() async {
    final engine = await SyncEngine.create(
      Platform.isMacOS ? EngineMode.desktop : EngineMode.foreground,
      hooks: IosContinuedSync.hooks,
    );
    IosContinuedSync.onExpired = () => engine.handle({'cmd': 'cancel'});
    await scheduleIosBackgroundSync(engine.settings.backgroundSync);
    if (engine.settings.keepAlive) await IosContinuedSync.setKeepAlive(true);
    if (engine.settings.menuBarOnly) await MacBridge.setMenuBarOnly(true);
    return LocalSyncClient._(engine);
  }

  void _refresh() {
    _state = EngineState(_engine.toState());
    notifyListeners();
  }

  @override
  EngineState? get state => _state;

  @override
  void send(String cmd, [Map<String, dynamic> args = const {}]) {
    if (cmd == 'setToggle' && args['key'] == 'backgroundSync') {
      scheduleIosBackgroundSync(args['value'] == true);
    }
    if (cmd == 'setToggle' && args['key'] == 'keepAlive') {
      IosContinuedSync.setKeepAlive(args['value'] == true);
    }
    if (cmd == 'setToggle' && args['key'] == 'menuBarOnly') {
      MacBridge.setMenuBarOnly(args['value'] == true);
    }
    _engine.handle({'cmd': cmd, ...args});
  }
}

/// Engine in the Android foreground service; we exchange messages with it.
class ServiceSyncClient extends SyncClient {
  ServiceSyncClient._();

  EngineState? _state;
  Timer? _hello;

  static Future<ServiceSyncClient> start() async {
    final c = ServiceSyncClient._();
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(c._onData);
    await startAndroidService();
    // The service may still be booting its engine; keep saying hello until
    // the first snapshot arrives.
    c._hello = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (c._state == null) {
        FlutterForegroundTask.sendDataToTask({'cmd': 'hello'});
      } else {
        c._hello?.cancel();
      }
    });
    FlutterForegroundTask.sendDataToTask({'cmd': 'hello'});
    return c;
  }

  void _onData(Object data) {
    if (data is Map) {
      _state = EngineState(data.cast<String, dynamic>());
      notifyListeners();
    }
  }

  @override
  EngineState? get state => _state;

  @override
  void send(String cmd, [Map<String, dynamic> args = const {}]) {
    FlutterForegroundTask.sendDataToTask({'cmd': cmd, ...args});
  }

  @override
  void dispose() {
    _hello?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    super.dispose();
  }
}
