/// "512 B", "3.4 MB", "1.2 GB".
String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
}

/// One line for a transfer in progress, e.g.
/// "45% · 12.3 MB of 27.0 MB · 3.2 MB/s".
String formatTransfer(Map<String, dynamic> p) {
  final pct = (((p['frac'] as num?) ?? 0) * 100).clamp(0, 100).floor();
  final size = (p['size'] as num?) ?? 0;
  final speed = p['speed'] as num?;
  return [
    '$pct%',
    if (size > 0)
      '${formatBytes((p['bytes'] as num?) ?? 0)} of ${formatBytes(size)}',
    if (speed != null && speed > 0) '${formatBytes(speed)}/s',
  ].join(' · ');
}
