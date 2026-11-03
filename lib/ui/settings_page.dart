import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/mac_bridge.dart';
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
                      ? 'Sends to your other devices whenever they’re reachable'
                      : Platform.isMacOS
                      ? 'Sends photos and videos from the photos folder below '
                            'to every connected device that allows inbound'
                      : 'Sends whenever your other devices are reachable and '
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
              if (Platform.isMacOS)
                _FolderTile(
                  icon: Icons.photo_library_outlined,
                  title: 'Photos folder',
                  path: s.photosFolder,
                  hint:
                      'Photos and videos here (and in subfolders) are sent; '
                      'photos received with inbound on are saved here.',
                  onPick: (path) => c.send('setFolder', {
                    'key': 'photosFolder',
                    'path': path,
                  }),
                )
              else
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
                title: const Text('Re-check sent photos'),
                subtitle: const Text(
                  'Asks the other devices again. Photos they still have are '
                  'skipped; any they deleted are sent again.',
                ),
                onTap: () {
                  c.send('resetSent');
                  c.send('sync');
                },
              ),
              ListTile(
                leading: const Icon(Icons.event_repeat),
                title: const Text('Fix dates of photos sent earlier'),
                subtitle: const Text(
                  'For copies saved with the day they arrived (e.g. WhatsApp '
                  'photos from before 1.0.1). Camera photos aren’t touched.',
                ),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    helpText: 'Fix photos taken since',
                    initialDate: DateTime.now().subtract(
                      const Duration(days: 60),
                    ),
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    c.send('fixDates', {
                      'sinceMs': picked.millisecondsSinceEpoch,
                    });
                  }
                },
              ),
              if (_knownDevices(s).isNotEmpty) ...[
                const _Header('Auto-send to'),
                for (final d in _knownDevices(s))
                  SwitchListTile(
                    secondary: Icon(switch (d.os) {
                      'ios' => Icons.phone_iphone,
                      'macos' => Icons.laptop_mac,
                      _ => Icons.phone_android,
                    }),
                    title: Text(d.name),
                    subtitle: const Text(
                      'New photos go here automatically. Off: only when '
                      'you send them yourself.',
                    ),
                    value: !s.noAutoTo.contains(d.id),
                    onChanged: (v) =>
                        c.send('setAutoTo', {'id': d.id, 'on': v}),
                  ),
              ],
              if (!Platform.isMacOS) ...[
                const _Header('Battery & data'),
                SwitchListTile(
                  secondary: const Icon(Icons.wifi),
                  title: const Text('Auto-send on Wi-Fi only'),
                  subtitle: const Text(
                    'Waits for Wi-Fi instead of using mobile data (also '
                    'over Tailscale). Sending by hand still works.',
                  ),
                  value: s.wifiOnly,
                  onChanged: (v) => toggle('wifiOnly', v),
                ),
                if (Platform.isAndroid)
                  SwitchListTile(
                    secondary: const Icon(Icons.battery_alert_outlined),
                    title: const Text('Pause on low battery'),
                    subtitle: const Text(
                      'Below 15% and not charging, auto-send waits.',
                    ),
                    value: s.lowBatteryPause,
                    onChanged: (v) => toggle('lowBatteryPause', v),
                  ),
              ],
              const _Header('Receiving'),
              SwitchListTile(
                secondary: const Icon(Icons.move_to_inbox_outlined),
                title: const Text('Allow inbound photos'),
                subtitle: Text(
                  s.inbound
                      ? 'Photos other devices send are saved '
                            '${Platform.isMacOS ? 'to the photos folder' : 'to this phone'}.'
                      : 'Other devices don’t send photos here. Files you send '
                            'on purpose still arrive.',
                ),
                value: s.inbound,
                onChanged: (v) => toggle('inbound', v),
              ),
              if (Platform.isMacOS)
                _FolderTile(
                  icon: Icons.folder_outlined,
                  title: 'Files folder',
                  path: s.filesFolder,
                  hint: 'Files sent from your phones are saved here.',
                  onPick: (path) =>
                      c.send('setFolder', {'key': 'filesFolder', 'path': path}),
                ),
              const _Header('Background'),
              if (Platform.isMacOS) ...[
                const _LaunchAtLoginTile(),
                SwitchListTile(
                  secondary: const Icon(Icons.menu),
                  title: const Text('Show in menu bar only'),
                  subtitle: const Text(
                    'No Dock icon; open or quit PhotoBridge from its menu '
                    'bar icon.',
                  ),
                  value: s.menuBarOnly,
                  onChanged: (v) => toggle('menuBarOnly', v),
                ),
                const ListTile(
                  leading: Icon(Icons.laptop_mac),
                  title: Text('Runs while the app is open'),
                  subtitle: Text(
                    'Closing the window keeps PhotoBridge running; click its '
                    'Dock (or menu bar) icon to bring it back. Quit it (⌘Q) '
                    'to stop. Nothing syncs while the Mac sleeps.',
                  ),
                ),
              ] else if (Platform.isAndroid)
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
                  secondary: const Icon(Icons.all_inclusive),
                  title: const Text('Keep running in background'),
                  subtitle: const Text(
                    'Keeps syncing after you leave the app by playing '
                    'silence (your music isn’t affected). Uses some '
                    'battery; iOS may still stop it on low memory or after '
                    'a restart.',
                  ),
                  value: s.keepAlive,
                  onChanged: (v) => toggle('keepAlive', v),
                ),
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

/// Devices seen (connected or found), by id, for per-device settings.
List<({String id, String name, String os})> _knownDevices(EngineState s) {
  final byId = <String, ({String id, String name, String os})>{};
  for (final d in [...s.peers, ...s.devices]) {
    final id = d['id'] as String?;
    if (id == null) continue;
    byId.putIfAbsent(
      id,
      () => (
        id: id,
        name: d['name'] as String? ?? id,
        os: d['os'] as String? ?? '',
      ),
    );
  }
  return byId.values.toList();
}

/// Mac: open at login, via macOS's own login items.
class _LaunchAtLoginTile extends StatefulWidget {
  const _LaunchAtLoginTile();

  @override
  State<_LaunchAtLoginTile> createState() => _LaunchAtLoginTileState();
}

class _LaunchAtLoginTileState extends State<_LaunchAtLoginTile> {
  bool? _on;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    MacBridge.launchAtLogin().then((v) {
      if (!mounted) return;
      setState(() {
        _on = v;
        _loaded = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded && _on == null) return const SizedBox.shrink();
    return SwitchListTile(
      secondary: const Icon(Icons.login),
      title: const Text('Open at login'),
      subtitle: const Text('Starts PhotoBridge when you log in to this Mac.'),
      value: _on ?? false,
      onChanged: !_loaded
          ? null
          : (v) async {
              try {
                final now = await MacBridge.setLaunchAtLogin(v);
                if (mounted) setState(() => _on = now);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
    );
  }
}

/// Mac: shows a folder and lets the user pick another one.
class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.icon,
    required this.title,
    required this.path,
    required this.hint,
    required this.onPick,
  });

  final IconData icon;
  final String title;
  final String path;
  final String hint;
  final void Function(String) onPick;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text('$path\n$hint'),
      isThreeLine: true,
      trailing: const Text('Change…'),
      onTap: () async {
        try {
          final picked = await FilePicker.getDirectoryPath(
            dialogTitle: title,
            initialDirectory: path,
          );
          if (picked != null) onPick(picked);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Could not open: $e')));
          }
        }
      },
    );
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
