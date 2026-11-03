import 'dart:async';
import 'dart:io';

import 'media_library.dart';
import 'server.dart' show DateFix;

/// The Mac's photos: a folder the user picks instead of the Photos app.
///
/// Every photo and video in it (subfolders too) is sent, whatever its date;
/// photos received with inbound on are saved into it. Ids are absolute
/// paths, so the sent ledger is per file.
class FolderLibrary implements PhotoSource {
  FolderLibrary(this.root);

  /// Current folder; read each time so a changed setting applies at once.
  final String Function() root;

  static const _images = {
    'jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'webp', 'tif', 'tiff', //
    'bmp', 'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2',
  };
  static const _videos = {'mov', 'mp4', 'm4v', 'avi', 'mkv', '3gp', 'hevc'};

  static String? kindOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = path.substring(dot + 1).toLowerCase();
    if (_images.contains(ext)) return 'image';
    if (_videos.contains(ext)) return 'video';
    return null;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<List<SourceItem>> pending({
    required DateTime since,
    required bool includeVideos,
  }) async {
    final dir = Directory(root());
    if (!await dir.exists()) return [];
    final items = <(File, DateTime)>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File || _hidden(e.path)) continue;
      final kind = kindOf(e.path);
      if (kind == null || (kind == 'video' && !includeVideos)) continue;
      items.add((e, await e.lastModified()));
    }
    items.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (f, t) in items) _item(f, t)];
  }

  @override
  Future<List<SourceItem>> byIds(List<String> ids) async => [
    for (final id in ids)
      if (await File(id).exists())
        _item(File(id), await File(id).lastModified()),
  ];

  @override
  Future<bool> exists(String id) => File(id).exists();

  /// A photo's subfolder (relative to the root) is its album.
  @override
  Future<Map<String, String>> albumsFor(Set<String> ids) async {
    final base = '${root()}/';
    return {
      for (final id in ids)
        if (id.startsWith(base) && id.substring(base.length).contains('/'))
          id: id.substring(base.length, id.lastIndexOf('/')),
    };
  }

  /// Finder shows a file's modified time; set it to when it was taken.
  @override
  Future<int> repairDates(List<DateFix> fixes) async {
    final dir = Directory(root());
    if (fixes.isEmpty || !await dir.exists()) return 0;
    final byName = {for (final f in fixes) f.name.toLowerCase(): f};
    var fixed = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final fix = byName[e.path.split('/').last.toLowerCase()];
      if (fix == null) continue;
      if ((await e.lastModified()).difference(fix.created).abs() <
          const Duration(minutes: 1)) {
        continue;
      }
      await e.setLastModified(fix.created);
      fixed++;
    }
    return fixed;
  }

  SourceItem _item(File f, DateTime modified) {
    final name = f.path.split('/').last;
    return SourceItem(
      id: f.path,
      title: name,
      created: modified,
      export: () async => ExportedAsset(f, name, kindOf(f.path) ?? 'image'),
    );
  }

  bool _hidden(String path) =>
      path.substring(root().length).split('/').any((s) => s.startsWith('.'));

  @override
  Future<void> releaseExports() async {}

  @override
  Future<String> save(
    File file, {
    required String name,
    required String kind,
    DateTime? created,
    (double, double)? location,
    String album = '',
  }) async {
    final dir = Directory(album.isEmpty ? root() : '${root()}/$album');
    await dir.create(recursive: true);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var dest = File('${dir.path}/$name');
    for (var n = 1; await dest.exists(); n++) {
      dest = File('${dir.path}/$stem ($n)$ext');
    }
    await file.copy(dest.path);
    // Finder sorts by date: show when it was taken, not when it arrived.
    if (created != null) await dest.setLastModified(created);
    return dest.path;
  }

  /// Fires when anything in the folder changes; the engine debounces.
  /// Creates the folder first, so a new (default) folder is watched too.
  Stream<void> watch() {
    final dir = Directory(root())..createSync(recursive: true);
    return dir.watch(recursive: true).map((_) {});
  }
}
