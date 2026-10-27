import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/client.dart';
import 'package:photobridge/core/protocol.dart';
import 'package:photobridge/core/scanner.dart';
import 'package:photobridge/core/server.dart';
import 'package:photobridge/core/settings.dart';

void main() {
  group('parseAddress', () {
    test('handles ipv4, ports and ipv6', () {
      expect(parseAddress('100.64.0.2'), ('100.64.0.2', kDefaultPort));
      expect(parseAddress(' 100.64.0.2:9000 '), ('100.64.0.2', 9000));
      expect(parseAddress('[fd7a::1]:9000'), ('fd7a::1', 9000));
      expect(parseAddress('fd7a::1'), ('fd7a::1', kDefaultPort));
      expect(parseAddress(''), isNull);
    });
  });

  group('subnetHosts', () {
    test('uses the real /21 mask, not a /24', () {
      final hosts = subnetHosts(
        '192.168.181.87',
        maskFromString('255.255.248.0'),
      );
      expect(hosts, hasLength(2045)); // 2046 usable minus ourselves
      expect(hosts.first, '192.168.176.1');
      expect(hosts.last, '192.168.183.254');
      expect(hosts, contains('192.168.179.160'));
      expect(hosts, isNot(contains('192.168.181.87')));
    });

    test('caps huge networks at a /20', () {
      final hosts = subnetHosts('10.1.200.5', maskFromString('255.0.0.0'));
      expect(hosts, hasLength(4093));
      expect(hosts.first, '10.1.192.1');
    });

    test('plain /24', () {
      expect(subnetHosts('192.168.1.10', 0xFFFFFF00), hasLength(253));
    });
  });

  test('pairing codes normalize', () {
    expect(normalizePairingCode('abcd-2345'), 'ABCD2345');
    expect(formatPairingCode('ABCD2345'), 'ABCD-2345');
    expect(generatePairingCode(), hasLength(8));
  });

  group('server/client round trip', () {
    late Directory tmp;
    late ReceiveServer server;
    late PeerClient client;
    final received = <String, List<int>>{};
    final have = <String>{};
    var key = 'SECRET12';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pb');
      received.clear();
      have.clear();
      key = 'SECRET12';
      server = ReceiveServer(
        selfInfo: () => {'id': 'recv', 'name': 'Pixel', 'os': 'android'},
        currentKey: () => 'SECRET12',
        alreadyHave: (s, a) => have.contains('$s|$a'),
        onFile: (f) async {
          received[f.name] = await f.file.readAsBytes();
          have.add('${f.senderId}|${f.assetId}');
          expect(f.kind, 'video');
          expect(f.created, DateTime.fromMillisecondsSinceEpoch(1700000000000));
        },
        tempRoot: tmp,
      );
      await server.start();
      client = PeerClient(selfId: 'send', key: () => key);
    });

    tearDown(() async {
      client.close();
      await server.stop();
      await tmp.delete(recursive: true);
    });

    test('uploads, dedupes and rejects a wrong key', () async {
      final info = await client.probe('127.0.0.1', server.port);
      expect(info!.id, 'recv');
      expect(info.paired, isTrue);
      final peer = Peer(info, '127.0.0.1', server.port);

      final src = File('${tmp.path}/src.bin')
        ..writeAsBytesSync(List.generate(3 * 1024 * 1024, (i) => i % 251));
      var lastProgress = 0;
      Future<String> send() => client.upload(
        peer,
        assetId: 'A1',
        file: src,
        name: 'Trip clip #1.MOV',
        kind: 'video',
        created: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        onProgress: (s, _) => lastProgress = s,
      );

      expect(await client.has(peer, 'A1'), isFalse);
      expect(await send(), 'saved');
      expect(lastProgress, src.lengthSync());
      expect(received['Trip clip #1.MOV'], src.readAsBytesSync());
      expect(await client.has(peer, 'A1'), isTrue);
      expect(await send(), 'duplicate');
      // Staging folder is cleaned up after each upload.
      expect(Directory('${tmp.path}/incoming').listSync(), isEmpty);

      key = 'WRONG999';
      expect((await client.probe('127.0.0.1', server.port))!.paired, isFalse);
      await expectLater(
        send(),
        throwsA(
          isA<TransferException>().having(
            (e) => e.unauthorized,
            'unauthorized',
            isTrue,
          ),
        ),
      );
    });
  });
}
