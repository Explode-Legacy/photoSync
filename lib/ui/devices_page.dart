import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../core/settings.dart';
import '../core/sync_client.dart';

/// Saved addresses (home, office, Tailscale…) plus devices found by scanning.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.client});

  final SyncClient client;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  SyncClient get c => widget.client;

  @override
  void initState() {
    super.initState();
    c.send('scan');
  }

  Future<void> _edit({SavedPeer? existing, String? label, String? address}) {
    return showDialog<void>(
      context: context,
      builder: (_) => _PeerDialog(
        client: c,
        existing: existing,
        initialLabel: existing?.label ?? label ?? '',
        initialAddress: existing?.address ?? address ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.state;
        if (s == null) return const Scaffold();
        final peerAddress = s.peer?['address'];
        final reachable = s.reachable;
        final saved = s.savedPeers;
        final savedAddrs = {for (final p in saved) p.address};
        final found = s.devices
            .where((d) => !savedAddrs.contains(d['address']))
            .toList();
        final text = Theme.of(context).textTheme;

        return Scaffold(
          appBar: AppBar(title: const Text('Devices')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _edit,
            icon: const Icon(Icons.add),
            label: const Text('Add address'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              _Section(
                'Saved',
                trailing: Text(
                  'Tried in order, plus Wi-Fi discovery',
                  style: text.bodySmall,
                ),
              ),
              if (saved.isEmpty)
                const ListTile(
                  leading: Icon(Icons.bookmark_border),
                  title: Text('No saved addresses'),
                  subtitle: Text(
                    'Add a Tailscale name like "pixel" or 100.x.y.z, or your '
                    'office/home IP. Or tap a device found below.',
                  ),
                ),
              for (final p in saved)
                _savedTile(
                  p,
                  online: reachable[_canonical(p.address)],
                  connected: _canonical(p.address) == peerAddress,
                ),
              _Section(
                'On this network',
                trailing: s.scanning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton.icon(
                        onPressed: () => c.send('scan'),
                        icon: const Icon(Icons.radar, size: 18),
                        label: const Text('Scan'),
                      ),
              ),
              if (found.isEmpty)
                ListTile(
                  leading: const Icon(Icons.wifi_find),
                  title: Text(
                    s.scanning ? 'Scanning…' : 'No other PhotoBridge found',
                  ),
                  subtitle: const Text(
                    'Open PhotoBridge on the other phone, on the same Wi-Fi.',
                  ),
                ),
              for (final d in found) _foundTile(d, d['address'] == peerAddress),
            ],
          ),
        );
      },
    );
  }

  Widget _savedTile(
    SavedPeer p, {
    required bool? online,
    required bool connected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final status = connected
        ? 'Connected'
        : online == null
        ? 'Not reachable now'
        : online
        ? 'Reachable'
        : 'Reachable, different pairing code';
    return ListTile(
      leading: Icon(
        connected ? Icons.check_circle : Icons.bookmark,
        color: connected
            ? Colors.green
            : online == null
            ? scheme.outline
            : scheme.primary,
      ),
      title: Text(p.label),
      subtitle: Text('${p.address} · $status'),
      onTap: () => _edit(existing: p),
      trailing: IconButton(
        tooltip: 'Remove',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => c.send('removePeer', {'address': p.address}),
      ),
    );
  }

  Widget _foundTile(Map<String, dynamic> d, bool connected) {
    final paired = d['paired'] == true;
    return ListTile(
      leading: Icon(
        d['os'] == 'ios' ? Icons.phone_iphone : Icons.phone_android,
        color: connected ? Colors.green : null,
      ),
      title: Text(d['name'] as String),
      subtitle: Text(
        '${d['address']} · ${connected
            ? 'Connected'
            : paired
            ? 'Paired'
            : 'Not paired: enter its code in Settings'}',
      ),
      trailing: TextButton(
        onPressed: () =>
            _edit(label: d['name'] as String, address: d['address'] as String),
        child: const Text('Save'),
      ),
    );
  }

  /// Saved entries may omit the default port; devices always include it.
  static String _canonical(String address) {
    final parsed = parseAddress(address);
    if (parsed == null) return address;
    final (host, port) = parsed;
    return host.contains(':') ? '[$host]:$port' : '$host:$port';
  }
}

class _PeerDialog extends StatefulWidget {
  const _PeerDialog({
    required this.client,
    required this.initialLabel,
    required this.initialAddress,
    this.existing,
  });

  final SyncClient client;
  final SavedPeer? existing;
  final String initialLabel;
  final String initialAddress;

  @override
  State<_PeerDialog> createState() => _PeerDialogState();
}

class _PeerDialogState extends State<_PeerDialog> {
  late final _label = TextEditingController(text: widget.initialLabel);
  late final _address = TextEditingController(text: widget.initialAddress);
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _address.dispose();
    super.dispose();
  }

  void _save() {
    final address = _address.text.trim();
    if (parseAddress(address) == null) {
      setState(() => _error = 'Enter an IP or name, e.g. 100.64.0.2 or pixel');
      return;
    }
    widget.client.send('savePeer', {
      'label': _label.text,
      'address': address,
      'replacing': ?widget.existing?.address,
    });
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add address' : 'Edit address'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _label,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Label',
              hintText: 'Home, Office, Tailscale…',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Address',
              hintText: '100.64.0.2 or pixel.tailnet.ts.net',
              helperText: 'Port $kDefaultPort is used if you leave it out',
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
