import 'dart:io';

import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../core/sync_client.dart';
import 'devices_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.client});

  final SyncClient client;

  @override
  Widget build(BuildContext context) {
    final c = client;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state;
        if (s == null) return const Scaffold();
        final since = MaterialLocalizations.of(context)
            .formatMediumDate(s.syncSince);
        void toggle(String key, bool v) =>
            c.send('setToggle', {'key': key, 'value': v});

        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            children: [
              const _Header('Pair'),
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Enter the other phone’s code'),
                subtitle: Text(
                  'This phone: ${formatPairingCode(s.pairingCode)}. Type the '
                  'code shown on your other phone here, once.',
                ),
                onTap: () => _editText(
                  context,
                  title: 'Pairing code',
                  hint: 'ABCD-2345',
                  onSave: (v) {
                    if (normalizePairingCode(v).length < 6) {
                      throw ArgumentError('Code is too short');
                    }
                    c.send('setPairingCode', {'code': v});
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('New pairing code'),
                subtitle: const Text('Unpairs the other phone'),
                onTap: () => c.send('newPairingCode'),
              ),
              const _Header('Connection'),
              ListTile(
                leading: const Icon(Icons.devices_other_outlined),
                title: const Text('Devices & addresses'),
                subtitle: Text(
                  s.savedPeers.isEmpty
                      ? 'Scan the network or add Tailscale/office addresses'
                      : s.savedPeers.map((p) => p.label).join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => DevicesPage(client: c)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: const Text('Device name'),
                subtitle: Text(s.deviceName),
                onTap: () => _editText(
                  context,
                  title: 'Device name',
                  initial: s.deviceName,
                  onSave: (v) => c.send('setDeviceName', {'name': v}),
                ),
              ),
              const _Header('Sending'),
              SwitchListTile(
                secondary: const Icon(Icons.sync),
                title: const Text('Auto-send new photos'),
                subtitle: Text(
                  Platform.isAndroid
                      ? 'Sends to the other phone whenever it’s reachable'
                      : 'Sends whenever the other phone is reachable and '
                            'iOS lets the app run',
                ),
                value: s.autoSend,
                onChanged: (v) => toggle('autoSend', v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.videocam_outlined),
                title: const Text('Include videos'),
                value: s.includeVideos,
                onChanged: (v) => toggle('includeVideos', v),
              ),
              ListTile(
                leading: const Icon(Icons.event),
                title: const Text('Send photos taken since'),
                subtitle: Text(since),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: s.syncSince,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    c.send('setSyncSince', {
                      'ms': picked.millisecondsSinceEpoch,
                    });
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Forget sent history'),
                subtitle: const Text(
                  'Re-check everything since the date above. The other phone '
                  'still skips photos it already has.',
                ),
                onTap: () => c.send('resetSent'),
              ),
              const _Header('Background'),
              if (Platform.isAndroid)
                const ListTile(
                  leading: Icon(Icons.notifications_active_outlined),
                  title: Text('Always on'),
                  subtitle: Text(
                    'PhotoBridge runs as a background service with a small '
                    'notification. It keeps syncing after you close the app '
                    'and starts again after a reboot. On Xiaomi/Redmi phones '
                    'also allow Autostart and set Battery saver to “No '
                    'restrictions” for PhotoBridge.',
                  ),
                )
              else ...[
                SwitchListTile(
                  secondary: const Icon(Icons.update),
                  title: const Text('Background sync'),
                  subtitle: const Text(
                    'iOS wakes PhotoBridge from time to time (more often '
                    'while charging) to send new photos. A sync you start '
                    'keeps going after you leave the app.',
                  ),
                  value: s.backgroundSync,
                  onChanged: (v) => toggle('backgroundSync', v),
                ),
                const ListTile(
                  leading: Icon(Icons.wifi),
                  title: Text('Sync the moment you get home'),
                  subtitle: Text(
                    'Shortcuts app → Automation → New → Wi-Fi → choose your '
                    'network → Run Immediately → Open App → PhotoBridge.',
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required void Function(String) onSave,
    String initial = '',
    String? hint,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (value == null || value.trim().isEmpty) return;
    try {
      onSave(value);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
