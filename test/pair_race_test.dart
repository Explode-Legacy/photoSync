import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/server.dart';

import 'transfer_test.dart' show TestDevice;

void main() {
  test('two devices probing each other at once both pair', () async {
    final tmp = await Directory.systemTemp.createTemp('race');
    Future<(TestDevice, ReceiveServer)> make(String id, String name) async {
      final d = await TestDevice.make(id, 'J33UV2YV');
      final s = ReceiveServer(
        selfInfo: () => {'id': id, 'name': name, 'os': 'x'},
        identity: d.identity,
        trusted: (i) => d.trusted[i],
        pairingCode: d.stretched,
        onPaired: d.onPaired,
        alreadyHave: (_, _) async => false,
        onFile: (_) async {},
        tempRoot: await tmp.createTemp(id),
      );
      await s.start();
      return (d, s);
    }

    final (a, sa) = await make('aaaa', 'iPhone');
    final (b, sb) = await make('bbbb', 'Android');
    final ca = a.client(port: sa.port);
    final cb = b.client(port: sb.port);
    // Like the engine: several candidate addresses probed in parallel, from
    // both sides at the same moment.
    final results = await Future.wait([
      for (var i = 0; i < 3; i++) ca.probe('127.0.0.1', sb.port),
      for (var i = 0; i < 3; i++) cb.probe('127.0.0.1', sa.port),
    ]);
    // ignore: avoid_print
    print([for (final r in results) r?.paired]);
    final again = await Future.wait([
      ca.probe('127.0.0.1', sb.port),
      cb.probe('127.0.0.1', sa.port),
    ]);
    // ignore: avoid_print
    print('second round: ${[for (final r in again) r?.paired]}');
    expect(again.every((r) => r?.paired == true), isTrue);
    ca.close();
    cb.close();
    await sa.stop();
    await sb.stop();
  });
}
