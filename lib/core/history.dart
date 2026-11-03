import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One thing that arrived from another device.
class Received {
  Received({
    required this.name,
    required this.kind,
    required this.from,
    required this.at,
    this.path,
  });

  factory Received.fromJson(Map<String, dynamic> j) => Received(
    name: j['name'] as String,
    kind: j['kind'] as String,
    from: j['from'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
    path: j['path'] as String?,
  );

  final String name;

  /// `image`, `video` or `file`.
  final String kind;
  final String from;
  final DateTime at;

  /// Where it was saved, when it's a file that can be opened directly
  /// (files everywhere; photos on the Mac). Phone photos are in the gallery.
  final String? path;

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'from': from,
    'at': at.millisecondsSinceEpoch,
    'path': ?path,
  };
}

/// Received items, newest last, one JSON object per line.
///
/// The engine appends; the UI reads the file itself (on Android they live
/// in different isolates but share the app's storage).
class ReceivedHistory {
  static const _keep = 300;

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/received.jsonl');

  static Future<void> add(Received r) async {
    final f = await _file();
    await f.writeAsString(
      '${jsonEncode(r.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
    // Trim now and then rather than on every write.
    if (await f.length() > 200 * 1024) {
      final lines = await f.readAsLines();
      if (lines.length > _keep) {
        await f.writeAsString(
          '${lines.sublist(lines.length - _keep).join('\n')}\n',
          flush: true,
        );
      }
    }
  }

  /// Newest first.
  static Future<List<Received>> read() async {
    final f = await _file();
    if (!await f.exists()) return [];
    final out = <Received>[];
    for (final line in await f.readAsLines()) {
      try {
        out.add(Received.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out.reversed.toList();
  }

  static Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
