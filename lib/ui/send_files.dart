import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/file_store.dart';
import '../core/sync_client.dart';

/// A file to send: where to read it, and where it goes on the other phone.
typedef PickedFile = ({String path, String name, String dir, int size});

/// Picks files or a whole folder and asks before sending.
class FileSender {
  FileSender(this.client);

  final SyncClient client;

  /// iOS only: native folder picker that keeps access to the folder open
  /// (see FolderPicker in AppDelegate.swift).
  static const _channel = MethodChannel('photobridge/files');

  Future<void> pickFiles(BuildContext context) async {
    final picked = await FilePicker.pickFiles();
    final files = <PickedFile>[
      for (final f in picked)
        if (f.path case final path?)
          (path: path, name: f.name, dir: '', size: await File(path).length()),
    ];
    if (context.mounted) await _confirmAndSend(context, files, null);
  }

  Future<void> pickFolder(BuildContext context) async {
    try {
      final root = await _pickFolderPath();
      if (root == null) return;
      final files = await _listFolder(root);
      if (!context.mounted) return;
      if (files.isEmpty) {
        _snack(context, 'That folder has no files');
        return;
      }
      await _confirmAndSend(context, files, files.first.dir.split('/').first);
    } on FileSystemException catch (e) {
      if (context.mounted) {
        _snack(context, 'Could not read the folder: ${e.message}');
      }
    } on _AccessDenied {
      if (context.mounted) {
        _snack(context, 'Allow "All files access" to send folders');
      }
    }
  }

  Future<String?> _pickFolderPath() async {
    if (Platform.isIOS) return _channel.invokeMethod<String>('pickFolder');
    final path = await FilePicker.getDirectoryPath();
    if (path == null) return null;
    // Android only lets an app read other folders with "All files access".
    if (!await Permission.manageExternalStorage.isGranted &&
        !(await Permission.manageExternalStorage.request()).isGranted) {
      throw _AccessDenied();
    }
    return path;
  }

  /// Every non-hidden file under [root]. Each keeps its folder path,
  /// starting with the picked folder's own name.
  static Future<List<PickedFile>> _listFolder(String root) async {
    final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    final rootName = base.split('/').last;
    final out = <PickedFile>[];
    await for (final e in Directory(
      base,
    ).list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final parts = e.path
          .substring(base.length)
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.isEmpty || parts.any((s) => s.startsWith('.'))) continue;
      out.add((
        path: e.path,
        name: parts.last,
        dir: [rootName, ...parts.sublist(0, parts.length - 1)].join('/'),
        size: await e.length(),
      ));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  Future<void> _confirmAndSend(
    BuildContext context,
    List<PickedFile> files,
    String? folder,
  ) async {
    if (files.isEmpty) return;
    final to = client.state?.peer?['name'] ?? 'the other phone';
    final total = files.fold<int>(0, (sum, f) => sum + f.size);
    final what = folder != null
        ? 'the folder "$folder" (${_count(files.length)}, ${_size(total)})'
        : files.length == 1
        ? '"${files.first.name}" (${_size(total)})'
        : '${_count(files.length)} (${_size(total)})';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send files?'),
        content: Text('Send $what to $to?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    client.send('sendFiles', {
      'files': [
        for (final f in files) {'path': f.path, 'name': f.name, 'dir': f.dir},
      ],
    });
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _count(int n) => n == 1 ? '1 file' : '$n files';

  static String _size(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
  }
}

class _AccessDenied implements Exception {}

/// Home-screen card: send files or a folder to the connected phone.
class SendFilesCard extends StatelessWidget {
  const SendFilesCard({super.key, required this.state, required this.client});

  final EngineState state;
  final SyncClient client;

  @override
  Widget build(BuildContext context) {
    final sender = FileSender(client);
    final enabled = state.peer != null && !state.syncing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Send files', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Any file or folder, sent once. Files you receive are in '
              '${FileStore.location}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled ? () => sender.pickFiles(context) : null,
                    icon: const Icon(Icons.insert_drive_file_outlined),
                    label: const Text('Files…'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled
                        ? () => sender.pickFolder(context)
                        : null,
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('Folder…'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
