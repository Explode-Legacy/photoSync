import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/media_library.dart';
import '../core/sync_client.dart';

/// Grid of recent photos for picking exactly what to send.
class PickerPage extends StatefulWidget {
  const PickerPage({super.key, required this.client});

  final SyncClient client;

  @override
  State<PickerPage> createState() => _PickerPageState();
}

class _PickerPageState extends State<PickerPage> {
  final MediaLibrary _library = MediaLibrary();
  final List<AssetEntity> _assets = [];
  final Set<String> _selected = {};
  int _page = 0;
  bool _loading = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final batch = await _library.recentPage(_page);
    setState(() {
      _assets.addAll(batch);
      _page++;
      _done = batch.isEmpty;
      _loading = false;
    });
  }

  void _toggle(AssetEntity a) => setState(() {
    if (!_selected.remove(a.id)) _selected.add(a.id);
  });

  void _send() {
    final picked = _assets.where((a) => _selected.contains(a.id)).toList()
      ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    widget.client.send('sync', {
      'assetIds': [for (final a in picked) a.id],
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selected.isEmpty ? 'Choose photos' : '${_selected.length} selected',
        ),
        actions: [
          if (_assets.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length == _assets.length) {
                  _selected.clear();
                } else {
                  _selected.addAll(_assets.map((a) => a.id));
                }
              }),
              child: Text(
                _selected.length == _assets.length ? 'None' : 'All loaded',
              ),
            ),
        ],
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _send,
              icon: const Icon(Icons.send),
              label: Text('Send ${_selected.length}'),
            ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) _loadMore();
          return false;
        },
        child: GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: _assets.length,
          itemBuilder: (context, i) {
            final a = _assets[i];
            return _Thumb(
              key: ValueKey(a.id),
              asset: a,
              selected: _selected.contains(a.id),
              onTap: () => _toggle(a),
            );
          },
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({
    super.key,
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _bytes = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize.square(240),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _bytes,
            builder: (context, snap) => snap.data == null
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : Image.memory(
                    snap.data!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
          ),
          if (widget.asset.type == AssetType.video)
            const Positioned(
              left: 4,
              bottom: 4,
              child: Icon(Icons.videocam, color: Colors.white, size: 18),
            ),
          if (widget.selected) ...[
            ColoredBox(color: scheme.primary.withValues(alpha: 0.35)),
            Positioned(
              right: 4,
              top: 4,
              child: Icon(Icons.check_circle, color: scheme.onPrimary),
            ),
          ],
        ],
      ),
    );
  }
}
