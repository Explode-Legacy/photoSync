import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Files other apps hand to PhotoBridge: the iPhone/Android share sheet,
/// and on the Mac, Open With or dropping onto the Dock icon.
///
/// Native code keeps them until we ask (so files shared while the app was
/// starting aren't lost) and nudges us with `sharedAvailable`.
class SharedInbox extends ChangeNotifier {
  static const _channel = MethodChannel('photobridge/files');

  final List<String> _pending = [];

  bool get hasFiles => _pending.isNotEmpty;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedAvailable') await _collect();
    });
    await _collect();
  }

  Future<void> _collect() async {
    try {
      final paths = await _channel.invokeListMethod<String>('takeShared');
      if (paths == null || paths.isEmpty) return;
      _pending.addAll(paths);
      notifyListeners();
    } on MissingPluginException {
      // Not wired up on this platform.
    }
  }

  /// Returns the waiting paths and forgets them.
  List<String> take() {
    final out = [..._pending];
    _pending.clear();
    return out;
  }
}
