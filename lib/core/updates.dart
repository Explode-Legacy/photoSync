import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A newer PhotoBridge on the public downloads page.
typedef Update = ({String version, Uri page});

/// Checks the public releases repository (the source repository is
/// private, so its releases can't be read without signing in).
abstract final class Updates {
  static const repo = 'Explode-Legacy/photoSync-releases';
  static const _lastCheck = 'updateLastCheck';
  static const _latest = 'updateLatest';

  /// The newest release if it's newer than this app. Asks GitHub at most
  /// once a day; otherwise answers from the last result.
  static Future<Update?> check({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(_lastCheck) ?? 0;
    var latest = prefs.getString(_latest);
    if (force || now - last > const Duration(days: 1).inMilliseconds) {
      final fetched = await _fetchLatestTag();
      if (fetched != null) {
        latest = fetched;
        await prefs.setString(_latest, fetched);
      }
      await prefs.setInt(_lastCheck, now);
    }
    if (latest == null) return null;
    final current = (await PackageInfo.fromPlatform()).version;
    if (compareVersions(latest, current) <= 0) return null;
    return (
      version: latest.replaceFirst('v', ''),
      page: Uri.parse('https://github.com/$repo/releases/latest'),
    );
  }

  static Future<String?> _fetchLatestTag() async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await http.getUrl(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      );
      req.headers.set('accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final json = jsonDecode(await utf8.decodeStream(res));
      return (json as Map<String, dynamic>)['tag_name'] as String?;
    } catch (_) {
      return null;
    } finally {
      http.close(force: true);
    }
  }

  /// Compares "v1.2.10" and "1.3.0" numerically; positive when [a] is newer.
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .replaceFirst(RegExp('^v'), '')
        .split(RegExp(r'[.+-]'))
        .take(3)
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }
}
