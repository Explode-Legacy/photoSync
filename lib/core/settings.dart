import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user settings and device identity.
class AppSettings {
  AppSettings._(this._p);

  final SharedPreferences _p;

  static Future<AppSettings> load() async {
    final s = AppSettings._(await SharedPreferences.getInstance());
    await s._ensureDefaults();
    return s;
  }

  Future<void> _ensureDefaults() async {
    if (_p.getString('deviceId') == null) {
      await _p.setString('deviceId', _randomString(16, _idAlphabet));
    }
    if (_p.getString('syncKey') == null) {
      await _p.setString('syncKey', generatePairingCode());
    }
    if (_p.getInt('syncSince') == null) {
      // Start from "now" so the first pairing doesn't dump the whole library.
      await _p.setInt('syncSince', DateTime.now().millisecondsSinceEpoch);
    }
    // v1 stored a single manual address; move it into the saved list.
    final legacy = _p.getString('manualPeer');
    if (legacy != null) {
      if (legacy.isNotEmpty) {
        await setSavedPeers([SavedPeer('Saved', legacy), ...savedPeers]);
      }
      await _p.remove('manualPeer');
    }
  }

  /// Picks up writes made by another isolate (e.g. a background task).
  Future<void> reload() => _p.reload();

  String get deviceId => _p.getString('deviceId')!;

  String get deviceName =>
      _p.getString('deviceName') ?? (Platform.isIOS ? 'iPhone' : 'Android');
  Future<void> setDeviceName(String v) => _p.setString('deviceName', v.trim());

  /// Shared secret. Both phones must hold the same value to talk.
  String get syncKey => _p.getString('syncKey')!;
  Future<void> setSyncKey(String v) => _p.setString('syncKey', v);

  /// Fixed addresses of the other phone: home/office IPs, Tailscale IPs or
  /// MagicDNS names. Tried in order alongside Wi-Fi discovery.
  List<SavedPeer> get savedPeers => (_p.getStringList('savedPeers') ?? [])
      .map((e) => SavedPeer.fromJson(jsonDecode(e) as Map<String, dynamic>))
      .toList();
  Future<void> setSavedPeers(List<SavedPeer> v) => _p.setStringList(
    'savedPeers',
    [for (final p in v) jsonEncode(p.toJson())],
  );

  /// Last address that worked, so background runs can skip discovery.
  String get lastPeer => _p.getString('lastPeer') ?? '';
  Future<void> setLastPeer(String v) => _p.setString('lastPeer', v);

  /// Send new photos automatically. On by default only on iPhone, since
  /// iPhone → Android is the main direction.
  bool get autoSend => _p.getBool('autoSend') ?? Platform.isIOS;
  Future<void> setAutoSend(bool v) => _p.setBool('autoSend', v);

  bool get includeVideos => _p.getBool('includeVideos') ?? true;
  Future<void> setIncludeVideos(bool v) => _p.setBool('includeVideos', v);

  /// Only photos taken at or after this moment are auto-sent.
  DateTime get syncSince =>
      DateTime.fromMillisecondsSinceEpoch(_p.getInt('syncSince')!);
  Future<void> setSyncSince(DateTime v) =>
      _p.setInt('syncSince', v.millisecondsSinceEpoch);

  /// Android: run as a foreground service that survives closing the app.
  /// iOS: let the system wake the app to sync.
  bool get backgroundSync => _p.getBool('backgroundSync') ?? true;
  Future<void> setBackgroundSync(bool v) => _p.setBool('backgroundSync', v);

  /// Last photo permission the UI saw, for engines that can't ask.
  bool get photoAccess => _p.getBool('photoAccess') ?? false;
  Future<void> setPhotoAccess(bool v) => _p.setBool('photoAccess', v);

  /// Simple toggles the UI may change by name.
  static const toggles = {'autoSend', 'includeVideos', 'backgroundSync'};

  Future<void> setToggle(String key, bool v) {
    if (!toggles.contains(key)) throw ArgumentError('Unknown setting $key');
    return _p.setBool(key, v);
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'syncKey': syncKey,
    'savedPeers': [for (final p in savedPeers) p.toJson()],
    'autoSend': autoSend,
    'includeVideos': includeVideos,
    'syncSince': syncSince.millisecondsSinceEpoch,
    'backgroundSync': backgroundSync,
  };
}

/// A user-named address for the other phone.
class SavedPeer {
  SavedPeer(this.label, this.address);

  factory SavedPeer.fromJson(Map<String, dynamic> j) =>
      SavedPeer(j['label'] as String? ?? '', j['address'] as String);

  final String label;
  final String address;

  Map<String, dynamic> toJson() => {'label': label, 'address': address};
}

// No 0/O/1/I so codes are easy to read off another screen.
const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _idAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

String _randomString(int length, String alphabet) {
  final r = Random.secure();
  return List.generate(
    length,
    (_) => alphabet[r.nextInt(alphabet.length)],
  ).join();
}

String generatePairingCode() => _randomString(8, _codeAlphabet);

/// Upper-cases and strips spaces/dashes so "abcd-2345" == "ABCD2345".
String normalizePairingCode(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

String formatPairingCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;
