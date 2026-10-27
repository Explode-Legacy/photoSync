import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'engine.dart';

/// Must match `BGTaskSchedulerPermittedIdentifiers` in ios/Runner/Info.plist
/// and the registrations in AppDelegate.swift.
const kIosRefreshTask = 'com.photobridge.app5ymxh.refresh';
const kIosProcessingTask = 'com.photobridge.app5ymxh.processing';

/// Runs in a headless engine when iOS wakes the app in the background.
@pragma('vm:entry-point')
void iosBackgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    // App refresh gets ~30s in total; processing tasks (idle/charging) get
    // minutes. Leave headroom so iOS doesn't kill us mid-file.
    final budget = task == kIosProcessingTask
        ? const Duration(minutes: 8)
        : const Duration(seconds: 22);
    final engine = await SyncEngine.create(EngineMode.iosBackground);
    try {
      await engine.runBackgroundSync(budget);
    } finally {
      await engine.dispose();
    }
    return true;
  });
}

Future<void> initIosBackground() async {
  if (!Platform.isIOS) return;
  await Workmanager().initialize(iosBackgroundDispatcher);
}

/// Asks iOS to wake us periodically (when it sees fit) and when charging.
Future<void> scheduleIosBackgroundSync(bool enabled) async {
  if (!Platform.isIOS) return;
  try {
    if (!enabled) {
      await Workmanager().cancelAll();
      return;
    }
    await Workmanager().registerPeriodicTask(
      kIosRefreshTask,
      kIosRefreshTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
    );
    await Workmanager().registerProcessingTask(
      kIosProcessingTask,
      kIosProcessingTask,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (_) {
    // Background App Refresh may be off in iOS Settings; the app still
    // syncs whenever it's open.
  }
}

/// Bridges to a native BGContinuedProcessingTask (iOS 26+), so a sync you
/// start keeps going after you leave the app, with progress shown by iOS.
/// Falls back to the classic ~30s background grace period on older iOS.
abstract final class IosContinuedSync {
  static const _channel = MethodChannel('photobridge/background');
  static bool _bound = false;

  /// Called when iOS takes the background time away.
  static VoidCallback? onExpired;

  static void _bind() {
    if (_bound || !Platform.isIOS) return;
    _bound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'expired') onExpired?.call();
    });
  }

  static Future<void> _invoke(String method, [Object? args]) async {
    if (!Platform.isIOS) return;
    _bind();
    try {
      await _channel.invokeMethod(method, args);
    } catch (_) {}
  }

  static final hooks = EngineHooks(
    onSyncStart: (total) => _invoke('begin', {'total': total}),
    onProgress: (done, total, name) =>
        _invoke('progress', {'done': done, 'total': total, 'name': name}),
    onSyncEnd: (sent) => _invoke('end', {'sent': sent}),
  );
}
