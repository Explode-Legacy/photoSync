import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../core/history.dart';
import '../core/sync_client.dart';

/// Everything received from other devices, newest first, with Open.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.client});

  final SyncClient client;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Received>? _items;
  int _version = -1;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_maybeReload);
    _reload();
  }

  @override
  void dispose() {
    widget.client.removeListener(_maybeReload);
    super.dispose();
  }

  void _maybeReload() {
    final v = widget.client.state?.historyVersion ?? 0;
    if (v != _version) _reload();
  }

  Future<void> _reload() async {
    _version = widget.client.state?.historyVersion ?? 0;
    final items = await ReceivedHistory.read();
    if (mounted) setState(() => _items = items);
  }

  Future<void> _open(Received r, {bool reveal = false}) async {
    final path = r.path!;
    if (!await File(path).exists()) {
      _snack('It was moved or deleted');
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [if (reveal) '-R', path]);
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) _snack(result.message);
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Received'),
        actions: [
          if (items != null && items.isNotEmpty)
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                await ReceivedHistory.clear();
                await _reload();
              },
            ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? const Center(child: Text('Nothing received yet.'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _tile(items[i]),
            ),
    );
  }

  Widget _tile(Received r) {
    final loc = MaterialLocalizations.of(context);
    final when =
        '${loc.formatShortDate(r.at)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(r.at))}';
    return ListTile(
      leading: Icon(switch (r.kind) {
        'image' => Icons.image_outlined,
        'video' => Icons.movie_outlined,
        _ => Icons.insert_drive_file_outlined,
      }),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        r.path == null
            ? 'From ${r.from} · $when · in your photo library'
            : 'From ${r.from} · $when',
      ),
      onTap: r.path == null ? null : () => _open(r),
      trailing: r.path == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (Platform.isMacOS)
                  IconButton(
                    tooltip: 'Show in Finder',
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: () => _open(r, reveal: true),
                  ),
                TextButton(
                  onPressed: () => _open(r),
                  child: const Text('Open'),
                ),
              ],
            ),
    );
  }
}
