import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/ui/format.dart';

void main() {
  test('formatBytes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(3.4 * 1024 * 1024), '3.4 MB');
  });

  test('formatTransfer shows percent, bytes and speed', () {
    expect(
      formatTransfer({
        'frac': 0.456,
        'bytes': 12 * 1048576,
        'size': 27 * 1048576,
        'speed': 3.2 * 1048576,
      }),
      '45% · 12.0 MB of 27.0 MB · 3.2 MB/s',
    );
    // Before the first measurement there's no speed yet.
    expect(formatTransfer({'frac': 0, 'bytes': 0, 'size': 0}), '0%');
  });
}
