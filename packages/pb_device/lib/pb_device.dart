import 'package:flutter/services.dart';

/// Battery level (0–100) and whether it's charging.
typedef BatteryState = ({int level, bool charging});

/// Device state for sync rules. A plugin (not a channel in MainActivity) so
/// it also works in the Android background service's own Flutter engine.
abstract final class PbDevice {
  static const _channel = MethodChannel('pb_device');

  /// Null where unavailable (other platforms, or no battery).
  static Future<BatteryState?> battery() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('battery');
      final level = m?['level'] as int?;
      if (level == null || level < 0) return null;
      return (level: level, charging: m?['charging'] == true);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
