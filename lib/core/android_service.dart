import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'engine.dart';

/// Android: the sync engine lives in this foreground-service isolate. It
/// keeps running after the app is closed or swiped away, and starts again
/// after a reboot.
void initAndroidService() {
  if (!Platform.isAndroid) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'photobridge_sync',
      channelName: 'Photo sync',
      channelDescription: 'Keeps PhotoBridge syncing in the background',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
      allowAutoRestart: true,
      stopWithTask: false,
    ),
  );
}

Future<void> startAndroidService() async {
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.requestNotificationPermission();
  final result = await FlutterForegroundTask.startService(
    // connectedDevice has no daily time limit, unlike dataSync on Android 15+.
    serviceTypes: [ForegroundServiceTypes.connectedDevice],
    notificationTitle: 'PhotoBridge',
    notificationText: 'Starting…',
    callback: androidServiceEntryPoint,
  );
  if (result is ServiceRequestFailure) throw result.error;
}

@pragma('vm:entry-point')
void androidServiceEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_EngineTask());
}

class _EngineTask extends TaskHandler {
  SyncEngine? _engine;
  final List<Map<String, dynamic>> _early = [];
  String _lastText = '';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final engine = await SyncEngine.create(EngineMode.androidService);
    engine.onChange = () => _publish(engine);
    _engine = engine;
    for (final cmd in _early) {
      await engine.handle(cmd);
    }
    _early.clear();
    _publish(engine);
  }

  void _publish(SyncEngine e) {
    FlutterForegroundTask.sendDataToMain(e.toState());
    final text = _statusText(e);
    if (text != _lastText) {
      _lastText = text;
      FlutterForegroundTask.updateService(notificationText: text);
    }
  }

  static String _statusText(SyncEngine e) {
    final p = e.peer;
    final where = p == null
        ? 'Waiting for your other phone'
        : 'Connected to ${p.info.name}';
    final counts = e.receivedCount + e.sentCount == 0
        ? ''
        : ' · ↓${e.receivedCount} ↑${e.sentCount}';
    return e.syncing ? 'Sending photos…$counts' : '$where$counts';
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final cmd = data.cast<String, dynamic>();
    final engine = _engine;
    if (engine == null) {
      if (cmd['cmd'] != 'hello') _early.add(cmd);
      return;
    }
    unawaited(engine.handle(cmd));
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _engine?.dispose();
    _engine = null;
  }
}
