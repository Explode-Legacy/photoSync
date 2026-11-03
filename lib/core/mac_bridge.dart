import 'dart:io';

import 'package:flutter/services.dart';

/// Mac-only settings handled natively (see MacBridge in AppDelegate.swift).
abstract final class MacBridge {
  static const _channel = MethodChannel('photobridge/mac');

  /// Whether PhotoBridge opens at login; null where unsupported (before
  /// macOS 13) or not a Mac.
  static Future<bool?> launchAtLogin() async {
    if (!Platform.isMacOS) return null;
    try {
      return await _channel.invokeMethod<bool>('launchAtLogin');
    } on PlatformException {
      return null;
    }
  }

  /// Returns the resulting state. Throws [PlatformException] with macOS's
  /// reason when it refuses.
  static Future<bool?> setLaunchAtLogin(bool on) =>
      _channel.invokeMethod<bool>('setLaunchAtLogin', {'on': on});

  /// Menu bar icon instead of a Dock icon.
  static Future<void> setMenuBarOnly(bool on) async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('setMenuBarOnly', {'on': on});
  }
}
