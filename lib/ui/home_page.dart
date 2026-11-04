import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/settings.dart';
import '../core/shared_inbox.dart';
import '../core/sync_client.dart';
import '../core/updates.dart';
import 'devices_page.dart';
import 'format.dart';
import 'history_page.dart';
import 'picker_page.dart';
import 'send_files.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.client});

  final SyncClient client;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  SyncClient get c => widget.client;
  final _shared = SharedInbox();
  Update? _update;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shared.addListener(_onShared);
    _shared.start();
    c.addListener(_publishDevices);
    Updates.check().then((u) {
      if (mounted) setState(() => _update = u);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_publishDevices);
    _shared.dispose();
    super.dispose();
  }

  /// Something was shared to PhotoBridge: ask where to send it, or, from
  /// the iPhone Share extension (devices already chosen), just send it.
  void _onShared() {
    if (!mounted) return;
    for (final job in _shared.takeJobs()) {
      c.send('sendFiles', {
        'to': job.to,
        'wait': true,
        'files': [
          for (final p in job.paths)
            {'path': p, 'name': p.split('/').last, 'dir': ''},
        ],
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sending ${job.paths.length} shared items')),
      );
    }
    if (_shared.hasFiles) FileSender(c).sendShared(context, _shared.take());
  }

  String _publishedDevices = '';

  /// iPhone: keeps the Share extension's device list current.
  void _publishDevices() {
    final s = c.state;
    if (s == null || !Platform.isIOS) return;
    final connected = {for (final p in s.peers) p['id']};
    final os = {
      for (final d in [...s.devices, ...s.peers]) d['id']: d['os'],
    };
    final list = <Map<String, Object>>[
      for (final t in s.trusted)
        {
          'id': t['id'] as String,
          'name': t['name'] as String,
          'os': (os[t['id']] as String?) ?? '',
          'connected': connected.contains(t['id']),
        },
    ];
    final key = list.toString();
    if (key == _publishedDevices) return;
    _publishedDevices = key;
    SharedInbox.publishDevices(list);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground || state == AppLifecycleState.paused) {
      c.send('lifecycle', {'foreground': foreground});
    }
  }

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('PhotoBridge'),
            actions: [
              IconButton(
                tooltip: 'Received',
                icon: const Icon(Icons.history),
                onPressed: () => _open(HistoryPage(client: c)),
              ),
              IconButton(
                tooltip: 'Devices',
                icon: const Icon(Icons.devices_other_outlined),
                onPressed: () => _open(DevicesPage(client: c)),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => _open(SettingsPage(client: c)),
              ),
            ],
          ),
          body: s == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: () async => c.send('refresh'),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (_update case final u?)
                        _UpdateBanner(
                          update: u,
                          onDismiss: () => setState(() => _update = null),
                        ),
                      if (!s.hasPhotoAccess) _PermissionBanner(client: c),
                      _ConnectionCard(
                        state: s,
                        onTap: () => _open(DevicesPage(client: c)),
                      ),
                      for (final r in s.incoming) ...[
                        const SizedBox(height: 12),
                        _ReceivingCard(info: r),
                      ],
                      const SizedBox(height: 12),
                      _SyncCard(
                        state: s,
                        client: c,
                        onChoose: () => _open(PickerPage(client: c)),
                      ),
                      const SizedBox(height: 12),
                      SendFilesCard(state: s, client: c),
                      const SizedBox(height: 12),
                      _ThisDeviceCard(state: s),
                      const SizedBox(height: 20),
                      Text(
                        'Activity',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      if (s.log.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('Nothing yet.'),
                        ),
                      for (final e in s.log.take(40)) _LogTile(entry: e),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.update, required this.onDismiss});

  final Update update;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.system_update_outlined),
        title: Text('PhotoBridge ${update.version} is available'),
        subtitle: Text(
          Platform.isIOS
              ? 'Download the IPA, then install it with SideStore.'
              : Platform.isMacOS
              ? 'Download the DMG and replace the app in Applications.'
              : 'Download the APK and install it over this one.',
        ),
        onTap: () => _openUrl(update.page),
        trailing: IconButton(
          tooltip: 'Later',
          icon: const Icon(Icons.close),
          onPressed: onDismiss,
        ),
      ),
    );
  }
}

Future<void> _openUrl(Uri url) async {
  if (Platform.isMacOS) {
    await Process.run('open', [url.toString()]);
  } else {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.client});

  final SyncClient client;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.photo_library_outlined),
        title: const Text('Photo access needed'),
        subtitle: const Text('Allow access to send and save photos.'),
        trailing: TextButton(
          onPressed: () async {
            final s = await PhotoManager.requestPermissionExtend();
            if (!s.hasAccess) await PhotoManager.openSetting();
            client.send('photoAccess', {'granted': s.hasAccess});
          },
          child: const Text('Allow'),
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.state, required this.onTap});

  final EngineState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peers = state.peers;
    final unpaired = state.devices.where((d) => d['paired'] != true).toList();

    final (
      IconData icon,
      Color color,
      String title,
      String subtitle,
    ) = switch (peers) {
      [_, ...] => (
        Icons.check_circle,
        Colors.green,
        'Connected to ${peers.map((p) => p['name']).join(', ')}',
        [
          for (final p in peers)
            '${peers.length > 1 ? '${p['name']}: ' : ''}via ${p['via']} · '
                '${p['address']}${p['inbound'] == false ? ' · inbound off' : ''}',
        ].join('\n'),
      ),
      _ when unpaired.isNotEmpty => (
        Icons.link_off,
        scheme.tertiary,
        'Found ${unpaired.first['name']}, not paired',
        'Enter its pairing code in Settings → Pair',
      ),
      _ => (
        Icons.wifi_find,
        scheme.outline,
        'Looking for your other devices…',
        'Tap to scan or add an address (Tailscale, office…)',
      ),
    };

    return Card(
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: color, size: 32),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({
    required this.state,
    required this.client,
    required this.onChoose,
  });

  final EngineState state;
  final SyncClient client;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final p = s.progress;
    final text = Theme.of(context).textTheme;
    final since = MaterialLocalizations.of(context)
        .formatMediumDate(s.syncSince);
    final online = s.peers.isNotEmpty;
    final background = Platform.isAndroid
        ? 'Runs in the background, even when closed'
        : Platform.isMacOS
        ? 'Syncs while PhotoBridge runs on this Mac'
        : s.backgroundSync
        ? 'iOS also syncs in the background now and then'
        : 'Syncs while the app is open';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              !s.autoSend
                  ? 'Auto-send is off · use Sync now'
                  : Platform.isMacOS
                  ? 'Auto-send is on · photos in ${s.photosFolder}'
                  : 'Auto-send is on · photos since $since',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '$background · Sent ${s.sentCount} · Received ${s.receivedCount}',
              style: text.bodySmall,
            ),
            if (p != null) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: (p['total'] as int) == 0
                    ? null
                    : ((p['done'] as int) + (p['frac'] as num)) /
                          (p['total'] as int),
              ),
              const SizedBox(height: 6),
              Text(
                '${(p['done'] as int) + 1} of ${p['total']} · ${p['current']}'
                '${p['to'] != null ? ' → ${p['to']}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
              Text(formatTransfer(p), style: text.bodySmall),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: s.syncing
                      ? OutlinedButton.icon(
                          onPressed: () => client.send('cancel'),
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        )
                      : FilledButton.icon(
                          onPressed: online ? () => client.send('sync') : null,
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync now'),
                        ),
                ),
                if (!Platform.isMacOS) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: !online || s.syncing || !s.hasPhotoAccess
                          ? null
                          : onChoose,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Choose…'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A file arriving from another device, with percentage and speed.
class _ReceivingCard extends StatelessWidget {
  const _ReceivingCard({required this.info});

  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final size = (info['size'] as num?) ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.south_west, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Receiving ${info['current']} from ${info['from']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: size == 0 ? null : (info['frac'] as num).toDouble(),
              color: Colors.green,
            ),
            const SizedBox(height: 6),
            Text(formatTransfer(info), style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.state});

  final EngineState state;

  @override
  Widget build(BuildContext context) {
    final code = formatPairingCode(state.pairingCode);
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This device · ${state.deviceName}', style: text.titleSmall),
            const SizedBox(height: 12),
            Text('Pairing code', style: text.labelMedium),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pairing code copied')),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  code,
                  style: text.headlineSmall?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Addresses (for Tailscale / manual)', style: text.labelMedium),
            const SizedBox(height: 2),
            if (state.addresses.isEmpty) const Text('No network'),
            for (final a in state.addresses)
              SelectableText('$a:${state.port}', style: text.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (entry['k']) {
      'sent' => (Icons.north_east, scheme.primary),
      'received' => (Icons.south_west, Colors.green),
      'error' => (Icons.error_outline, scheme.error),
      _ => (Icons.info_outline, scheme.outline),
    };
    final t = DateTime.fromMillisecondsSinceEpoch(entry['ms'] as int);
    final hhmm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color, size: 20),
      title: Text(entry['t'] as String),
      trailing: Text(hhmm, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
