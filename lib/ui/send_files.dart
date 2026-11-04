import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/file_store.dart';
import '../core/sync_client.dart';
import 'format.dart';

/// A file to send: where to read it, and where it goes on the other phone.
typedef PickedFile = ({String path, String name, String dir, int size});

/// Picks files or a whole folder and asks before sending.
class FileSender {
  FileSender(this.client);

  final SyncClient client;

  /// iOS only: native folder picker that keeps access to the folder open
  /// (see FolderPicker in AppDelegate.swift).
  static const _channel = MethodChannel('photobridge/files');

  Future<void> pickFiles(BuildContext context) =>
      _pick(context, FilePicker.pickFiles());

  /// Photos and videos from the gallery, sent as files (originals: no
  /// HEIC→JPEG or video conversion).
  Future<void> pickPhotos(BuildContext context) => _pick(
    context,
    FilePicker.pickFiles(
      type: FileType.media,
      darwinOptions: const DarwinOptions(
        assetRepresentationMode: DarwinAssetRepresentationMode.current,
        orderedSelection: false,
      ),
    ),
  );

  Future<void> _pick(
    BuildContext context,
    Future<List<PlatformFile>> picking,
  ) async {
    final picked = await picking;
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
    final total = files.fold<int>(0, (sum, f) => sum + f.size);
    final what = folder != null
        ? 'the folder "$folder" (${_count(files.length)}, ${formatBytes(total)})'
        : files.length == 1
        ? '"${files.first.name}" (${formatBytes(total)})'
        : '${_count(files.length)} (${formatBytes(total)})';
    final to = await showDialog<List<String>>(
      context: context,
      builder: (_) => _SendDialog(client: client, what: what),
    );
    if (to == null || to.isEmpty) return;
    client.send('sendFiles', {
      'to': to,
      'files': [
        for (final f in files) {'path': f.path, 'name': f.name, 'dir': f.dir},
      ],
    });
  }

  /// Files handed over by the share sheet, Open With or a Dock drop. A
  /// shared folder (Mac) goes with its structure, like "Folder…".
  Future<void> sendShared(BuildContext context, List<String> paths) async {
    final files = <PickedFile>[];
    String? folder;
    for (final path in paths) {
      if (await FileSystemEntity.isDirectory(path)) {
        final inside = await _listFolder(path);
        files.addAll(inside);
        folder = paths.length == 1 ? path.split('/').last : null;
      } else if (await File(path).exists()) {
        files.add((
          path: path,
          name: path.split('/').last,
          dir: '',
          size: await File(path).length(),
        ));
      }
    }
    if (context.mounted) await _confirmAndSend(context, files, folder);
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _count(int n) => n == 1 ? '1 file' : '$n files';
}

class _AccessDenied implements Exception {}

/// "Send … to:" with a checkbox per connected device, all ticked at first.
/// Pops the chosen device ids.
class _SendDialog extends StatefulWidget {
  const _SendDialog({required this.client, required this.what});

  final SyncClient client;
  final String what;

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  /// Unticked device ids; new devices that connect meanwhile start ticked.
  final _off = <String>{};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.client,
      builder: (context, _) {
        final peers = widget.client.state?.peers ?? [];
        final chosen = [
          for (final p in peers)
            if (!_off.contains(p['id'])) p['id'] as String,
        ];
        return AlertDialog(
          title: const Text('Send files'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send ${widget.what} to:'),
              const SizedBox(height: 8),
              if (peers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No devices connected. Open PhotoBridge on '
                    'the other device.',
                  ),
                ),
              for (final p in peers)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(switch (p['os']) {
                    'ios' => Icons.phone_iphone,
                    'macos' => Icons.laptop_mac,
                    _ => Icons.phone_android,
                  }),
                  title: Text(p['name'] as String),
                  subtitle: Text('via ${p['via']}'),
                  value: !_off.contains(p['id']),
                  onChanged: (v) => setState(() {
                    final id = p['id'] as String;
                    v == true ? _off.remove(id) : _off.add(id);
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(context, chosen),
              child: const Text('Send'),
            ),
          ],
        );
      },
    );
  }
}

/// Home-screen card: send files or a folder to connected devices.
class SendFilesCard extends StatelessWidget {
  const SendFilesCard({super.key, required this.state, required this.client});

  final EngineState state;
  final SyncClient client;

  @override
  Widget build(BuildContext context) {
    final sender = FileSender(client);
    final enabled = state.peers.isNotEmpty && !state.syncing;
    final location = Platform.isMacOS ? state.filesFolder : FileStore.location;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Send files', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Photos, files or folders, sent once as files (not synced). '
              'What you receive is in '
              '$location.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                // The Mac has no photo library here; it uses Files/Folder.
                if (!Platform.isMacOS) ...[
                  _SendChoice(
                    icon: Icons.photo_library_outlined,
                    label: 'Photos',
                    onTap: enabled ? () => sender.pickPhotos(context) : null,
                  ),
                  const SizedBox(width: 8),
                ],
                _SendChoice(
                  icon: Icons.insert_drive_file_outlined,
                  label: 'Files',
                  onTap: enabled ? () => sender.pickFiles(context) : null,
                ),
                const SizedBox(width: 8),
                _SendChoice(
                  icon: Icons.folder_outlined,
                  label: 'Folder',
                  onTap: enabled ? () => sender.pickFolder(context) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the Send files choices: icon above label, so three fit a phone.
class _SendChoice extends StatelessWidget {
  const _SendChoice({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 6),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
