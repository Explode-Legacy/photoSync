part of 'engine.dart';

/// Sending photos, videos and files.
extension EngineSending on SyncEngine {
  // ---------------------------------------------------------------- sending

  /// Devices that accept photos right now. Automatic syncs also skip the
  /// ones turned off under Settings → Auto-send to.
  List<Peer> _photoTargets({required bool manual}) => [
    for (final p in peers.values)
      if (p.info.inbound && (manual || !settings.noAutoTo.contains(p.info.id)))
        p,
  ];

  /// Why automatic sending should wait right now, or null to go ahead.
  Future<String?> _autoBlocked() async {
    if (Platform.isMacOS) return null;
    if (settings.wifiOnly) {
      final links = await Connectivity().checkConnectivity();
      if (!links.contains(ConnectivityResult.wifi) &&
          !links.contains(ConnectivityResult.ethernet)) {
        return 'Waiting for Wi-Fi (Wi-Fi only is on)';
      }
    }
    if (settings.lowBatteryPause) {
      final b = await PbDevice.battery();
      if (b != null && !b.charging && b.level < 15) {
        return 'Paused: battery below 15%';
      }
    }
    return null;
  }

  /// Sends everything new since [AppSettings.syncSince] (the Mac: everything
  /// in its photos folder) to every connected device that accepts photos,
  /// or exactly [assetIds] when given (manual pick; re-sends even if sent
  /// before). Stops early at [deadline] (background tasks have little time).
  Future<int> syncNow({
    List<String>? assetIds,
    DateTime? deadline,
    bool auto = false,
  }) async {
    if (syncing) {
      if (assetIds == null) _syncAgain = true;
      return 0;
    }
    if (peers.isEmpty) {
      _addLog('error', 'No other device found yet');
      return 0;
    }
    final targets = _photoTargets(manual: !auto);
    if (targets.isEmpty) {
      if (assetIds != null) {
        _addLog('error', 'Connected devices have inbound turned off');
      }
      return 0;
    }
    if (!hasPhotoAccess) {
      _addLog('error', 'Photo access is off. Open the app to allow it.');
      return 0;
    }

    syncing = true;
    _cancel = false;
    _changed();
    final sentTo = <String, int>{};
    var sentNow = 0;
    try {
      final manual = assetIds != null;
      final candidates = manual
          ? await _library.byIds(assetIds)
          : await _library.pending(
              since: settings.syncSince,
              includeVideos: settings.includeVideos,
            );
      bool needs(Peer t, SourceItem a) =>
          manual || !_sent.contains('${t.info.id}|${a.id}');
      final queue = [
        for (final a in candidates)
          if (manual || !_imported.contains(a.id))
            if (targets.any((t) => needs(t, a))) a,
      ];
      if (queue.isEmpty) return 0;

      _addLog(
        'info',
        'Sending ${queue.length} to '
            '${targets.map((t) => t.info.name).join(', ')}',
      );
      hooks.onSyncStart?.call(queue.length);
      final albums = await _library.albumsFor({for (final a in queue) a.id});
      // Targets drop out of this run when they fail (offline, wrong code).
      final active = [...targets];
      for (var i = 0; i < queue.length && !_cancel && active.isNotEmpty; i++) {
        if (deadline != null && DateTime.now().isAfter(deadline)) {
          _addLog('info', 'Out of background time, will continue later');
          break;
        }
        final item = queue[i];
        _setProgress(i, queue.length, item.title, 0);
        hooks.onProgress?.call(i, queue.length, item.title);
        // Exported once, then uploaded to each device that needs it.
        ExportedAsset? exported;
        for (final t in [...active]) {
          if (!needs(t, item)) continue;
          try {
            final sent = await _sendOne(
              t,
              item,
              () async => exported ??= await item.export(),
              i,
              queue.length,
              album: albums[item.id],
            );
            if (sent) {
              sentNow++;
              sentTo.update(t.info.name, (n) => n + 1, ifAbsent: () => 1);
            }
          } on Exception catch (e) {
            if (_stopAfter(e, t)) active.remove(t);
          }
        }
        if (i % 10 == 9) await _library.releaseExports();
      }
      if (sentTo.isNotEmpty) {
        _addLog(
          'sent',
          'Sent ${[for (final e in sentTo.entries) '${e.value} to ${e.key}'].join(', ')}',
        );
      }
      if (_cancel) _addLog('info', 'Stopped');
    } catch (e) {
      _addLog('error', 'Sync failed: $e');
    } finally {
      await _library.releaseExports();
      syncing = false;
      _progress = null;
      hooks.onSyncEnd?.call(sentNow);
      _changed();
    }
    if (_syncAgain && !_cancel) {
      _syncAgain = false;
      unawaited(syncNow(deadline: deadline, auto: auto));
    }
    return sentNow;
  }

  /// Logs a failed transfer to [target]. Returns true when the rest of the
  /// batch should skip it (wrong pairing code, inbound off, network gone);
  /// rethrows the unknown.
  bool _stopAfter(Exception e, Peer target) {
    final name = target.info.name;
    switch (e) {
      case TransferException():
        _addLog('error', '$name: ${e.message}');
        return e.unauthorized || e.rejected;
      case IOException():
        // Network dropped: skip it, the next probe/sync resumes from here.
        _addLog('error', 'Lost $name: ${e.runtimeType}');
        peers.remove(target.info.id);
        return true;
      case TimeoutException():
        _addLog('error', '$name timed out, will retry later');
        peers.remove(target.info.id);
        return true;
    }
    throw e;
  }

  /// Sends files the user picked (not photos) to the devices with ids in
  /// [to], or all connected ones. Each lands in the receiver's files folder
  /// under its [dir], so a picked folder arrives with its structure intact.
  /// Inbound doesn't apply: files are always sent on purpose.
  Future<int> sendFiles(
    List<({String path, String name, String dir})> files, {
    List<String>? to,
    bool wait = false,
  }) async {
    if (files.isEmpty) return 0;
    // [wait]: devices not connected (or a transfer already running) get the
    // files later instead of never.
    if (wait && to != null) {
      final later = {
        for (final id in to)
          if (syncing || !peers.containsKey(id)) id,
      };
      if (later.isNotEmpty) {
        _queuedFiles.add((files: files, to: later));
        _addLog(
          'info',
          '${_countFiles(files.length)} will be sent when the device connects',
        );
        to = [
          for (final id in to)
            if (!later.contains(id)) id,
        ];
        if (to.isEmpty) return 0;
      }
    }
    if (syncing) {
      _addLog('error', 'Wait for the current transfer to finish');
      return 0;
    }
    final targets = [
      for (final p in peers.values)
        if (to == null || to.contains(p.info.id)) p,
    ];
    if (targets.isEmpty) {
      _addLog('error', 'No other device found yet');
      return 0;
    }

    syncing = true;
    _cancel = false;
    _changed();
    var sentNow = 0;
    final batch = SyncEngine._now();
    try {
      final names = targets.map((t) => t.info.name).join(', ');
      _addLog('info', 'Sending ${_countFiles(files.length)} to $names');
      hooks.onSyncStart?.call(files.length);
      final active = [...targets];
      for (var i = 0; i < files.length && !_cancel && active.isNotEmpty; i++) {
        final f = files[i];
        _setProgress(i, files.length, f.name, 0);
        hooks.onProgress?.call(i, files.length, f.name);
        final file = File(f.path);
        if (!await file.exists()) {
          _addLog('error', 'Could not read ${f.name}');
          continue;
        }
        var delivered = false;
        for (final t in [...active]) {
          try {
            await _client.upload(
              t,
              // Unique per send: picking the same file again sends it again.
              assetId: 'file:$batch:$i',
              file: file,
              name: f.name,
              kind: 'file',
              dir: f.dir,
              created: await file.lastModified(),
              onProgress: _progressFor(i, files.length, f.name, t),
            );
            delivered = true;
          } on Exception catch (e) {
            if (_stopAfter(e, t)) active.remove(t);
          }
        }
        if (delivered) sentNow++;
      }
      if (sentNow > 0) {
        _addLog('sent', 'Sent ${_countFiles(sentNow)} to $names');
      }
      if (_cancel) _addLog('info', 'Stopped');
    } catch (e) {
      _addLog('error', 'Sending files failed: $e');
    } finally {
      syncing = false;
      _progress = null;
      hooks.onSyncEnd?.call(sentNow);
      _changed();
    }
    return sentNow;
  }

  static String _countFiles(int n) => n == 1 ? '1 file' : '$n files';

  /// Sends queued files to whichever of their devices are connected now.
  Future<void> _sendQueued() async {
    if (syncing || _queuedFiles.isEmpty) return;
    final ready = [
      for (final job in _queuedFiles)
        (
          job,
          {
            for (final id in job.to)
              if (peers.containsKey(id)) id,
          },
        ),
    ];
    for (final (job, ids) in ready) {
      if (ids.isEmpty) continue;
      job.to.removeAll(ids);
      await sendFiles(job.files, to: [...ids]);
    }
    _queuedFiles.removeWhere((j) => j.to.isEmpty);
  }

  /// What's being sent right now, for the UI and the Android notification:
  /// item [done] of [total], [frac] of the current file, its [bytes] of
  /// [size], [speed] in bytes/s, and the device it's going [to].
  Map<String, dynamic>? get progress => _progress;

  void _setProgress(
    int done,
    int total,
    String name,
    double frac, {
    int bytes = 0,
    int size = 0,
    double? speed,
    String? to,
  }) {
    _progress = {
      'done': done,
      'total': total,
      'current': name,
      'frac': frac,
      'bytes': bytes,
      'size': size,
      'speed': ?speed,
      'to': ?to,
    };
    _changed();
  }

  /// Upload progress callback for one file to [target]: updates the
  /// percentage and a smoothed speed, a few times a second.
  void Function(int sent, int total) _progressFor(
    int i,
    int n,
    String name,
    Peer target,
  ) {
    final meter = _SpeedMeter();
    return (sent, total) {
      if (!meter.update(sent, force: sent >= total)) return;
      _setProgress(
        i,
        n,
        name,
        total == 0 ? 1 : sent / total,
        bytes: sent,
        size: total,
        speed: meter.speed,
        to: peers.length > 1 ? target.info.name : null,
      );
    };
  }

  /// Returns true when a file was actually transferred.
  Future<bool> _sendOne(
    Peer target,
    SourceItem item,
    Future<ExportedAsset?> Function() export,
    int i,
    int n, {
    String? album,
  }) async {
    final ledgerKey = '${target.info.id}|${item.id}';
    if (await _client.has(target, item.id)) {
      await _sent.add(ledgerKey);
      return false;
    }
    final exported = await export();
    if (exported == null) {
      // A Live Photo without a usable motion part: the photo itself went.
      if (!item.id.endsWith(kLiveSuffix)) {
        _addLog('error', 'Could not read ${item.title}');
      }
      await _sent.add(ledgerKey);
      return false;
    }
    final status = await _client.upload(
      target,
      assetId: item.id,
      file: exported.file,
      name: exported.name,
      kind: exported.kind,
      created: item.created,
      location: item.location,
      album: album,
      onProgress: _progressFor(i, n, exported.name, target),
    );
    await _sent.add(ledgerKey);
    if (status == 'saved') sentCount++;
    return status == 'saved';
  }

  /// Sends the right capture dates for photos since [since] that were sent
  /// earlier, so receivers can fix copies saved with the wrong date (e.g.
  /// WhatsApp images saved before PhotoBridge 1.0.1).
  Future<void> fixDates(DateTime since) async {
    if (peers.isEmpty) {
      _addLog('error', 'No other device found yet');
      return;
    }
    try {
      final items = await _library.pending(since: since, includeVideos: false);
      for (final t in [...peers.values]) {
        final fixes = <DateFix>[
          for (final a in items)
            if (_sent.contains('${t.info.id}|${a.id}'))
              (name: a.title, created: a.created, location: a.location),
        ];
        if (fixes.isEmpty) continue;
        final fixed = await _client.fixDates(t, fixes);
        _addLog('info', 'Fixed dates of $fixed photos on ${t.info.name}');
      }
    } on Exception catch (e) {
      _addLog('error', 'Fixing dates failed: $e');
    }
  }

  /// Entry point for iOS background tasks: find the devices, send what's
  /// new within [budget], and return how many photos went out.
  Future<int> runBackgroundSync(Duration budget) async {
    final deadline = DateTime.now().add(budget);
    if (!settings.backgroundSync || !settings.autoSend) return 0;
    // Give Bonjour a moment; saved and last-known addresses work anyway.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _probe();
    if (peers.isEmpty || await _autoBlocked() != null) return 0;
    return syncNow(deadline: deadline, auto: true);
  }
}
