import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/settings.dart';
import '../core/sync_client.dart';
import 'devices_page.dart';
import 'picker_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.client});

  final SyncClient client;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  SyncClient get c => widget.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
                      if (!s.hasPhotoAccess) _PermissionBanner(client: c),
                      _ConnectionCard(
                        state: s,
                        onTap: () => _open(DevicesPage(client: c)),
                      ),
                      const SizedBox(height: 12),
                      _SyncCard(
                        state: s,
                        client: c,
                        onChoose: () => _open(PickerPage(client: c)),
                      ),
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
    final peer = state.peer;
    final unpaired = state.devices.where((d) => d['paired'] != true).toList();

    final (
      IconData icon,
      Color color,
      String title,
      String subtitle,
    ) = switch (peer) {
      final p? => (
        Icons.check_circle,
        Colors.green,
        'Connected to ${p['name']}',
        'via ${p['via']} · ${p['address']}',
      ),
      null when unpaired.isNotEmpty => (
        Icons.link_off,
        scheme.tertiary,
        'Found ${unpaired.first['name']}, not paired',
        'Enter its pairing code in Settings → Pair',
      ),
      null => (
        Icons.wifi_find,
        scheme.outline,
        'Looking for your other phone…',
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
    final online = s.peer != null;
    final background = Platform.isAndroid
        ? 'Runs in the background, even when closed'
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
              s.autoSend
                  ? 'Auto-send is on · photos since $since'
                  : 'Auto-send is off · use Sync now or Choose',
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
                '${(p['done'] as int) + 1} of ${p['total']} · ${p['current']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
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
            ),
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
            Text('This phone · ${state.deviceName}', style: text.titleSmall),
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
