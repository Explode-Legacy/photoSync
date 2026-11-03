import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where received files (not photos) are kept.
///
/// Android: Download/PhotoBridge, visible in any file manager. iPhone: the
/// app's Documents folder, shown in Files → On My iPhone → PhotoBridge.
/// Mac: the folder chosen in Settings ([macRoot]).
class FileStore {
  FileStore({required this.macRoot});

  final String Function() macRoot;

  static const _androidRoot = '/storage/emulated/0/Download/PhotoBridge';

  /// Human-readable location for the UI (the Mac shows its folder instead).
  static String get location => Platform.isAndroid
      ? 'Download › PhotoBridge'
      : 'Files › On My iPhone › PhotoBridge';

  Future<Directory> _root() async {
    if (Platform.isIOS) return getApplicationDocumentsDirectory();
    if (Platform.isMacOS) {
      return Directory(macRoot()).create(recursive: true);
    }
    final root = Directory(_androidRoot);
    await root.create(recursive: true);
    // Keeps received images out of the gallery, so they aren't auto-sent
    // back as photos.
    final noMedia = File('$_androidRoot/.nomedia');
    if (!await noMedia.exists()) await noMedia.create();
    return root;
  }

  /// Moves [incoming] to [dir]/[name] (both already sanitized), renaming to
  /// "name (1).ext" etc. when taken. Returns the full path, and the path
  /// relative to the root for showing.
  Future<({String path, String shown})> save(
    File incoming, {
    required String dir,
    required String name,
  }) async {
    final root = await _root();
    final folder = Directory(dir.isEmpty ? root.path : '${root.path}/$dir');
    await folder.create(recursive: true);
    final dest = await _unique(folder, name);
    try {
      await incoming.rename(dest.path);
    } on FileSystemException {
      // Different volume (app cache → shared storage): copy instead.
      await incoming.copy(dest.path);
    }
    return (path: dest.path, shown: dest.path.substring(root.path.length + 1));
  }

  static Future<File> _unique(Directory folder, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = File('${folder.path}/$name');
    for (var n = 1; await candidate.exists(); n++) {
      candidate = File('${folder.path}/$stem ($n)$ext');
    }
    return candidate;
  }
}
