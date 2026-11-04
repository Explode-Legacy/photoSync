import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Files other apps hand to PhotoBridge: the iPhone/Android share sheet
/// (including the iPhone Share extension, used by the Photos app), and on
/// the Mac, Open With or dropping onto the Dock icon.
///
/// Native code keeps them until we ask (so files shared while the app was
/// starting aren't lost) and nudges us with `sharedAvailable`.
class SharedInbox extends ChangeNotifier {
  static const _channel = MethodChannel('photobridge/files');

  final List<String> _pending = [];

  /// From the iPhone Share extension: files with the devices already chosen.
  final List<({List<String> to, List<String> paths})> _jobs = [];

  bool get hasFiles => _pending.isNotEmpty;
  bool get hasJobs => _jobs.isNotEmpty;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedAvailable') await _collect();
    });
    await _collect();
  }

  Future<void> _collect() async {
    var changed = false;
    try {
      final paths = await _channel.invokeListMethod<String>('takeShared');
      if (paths != null && paths.isNotEmpty) {
        _pending.addAll(paths);
        changed = true;
      }
      if (Platform.isIOS) {
        final jobs = await _channel.invokeListMethod<Map>('takeOutbox') ?? [];
        for (final j in jobs) {
          _jobs.add((
            to: (j['to'] as List).cast<String>(),
            paths: (j['paths'] as List).cast<String>(),
          ));
          changed = true;
        }
      }
    } on MissingPluginException {
      // Not wired up on this platform.
    }
    if (changed) notifyListeners();
  }

  List<({List<String> to, List<String> paths})> takeJobs() {
    final out = [..._jobs];
    _jobs.clear();
    return out;
  }

  /// iPhone: tells the Share extension which devices it can offer.
  static Future<void> publishDevices(List<Map<String, Object>> devices) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('publishDevices', devices);
    } catch (_) {}
  }

  /// Returns the waiting paths and forgets them.
  List<String> take() {
    final out = [..._pending];
    _pending.clear();
    return out;
  }
}
