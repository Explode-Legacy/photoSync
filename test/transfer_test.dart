import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/client.dart';
import 'package:photobridge/core/crypto.dart';
import 'package:photobridge/core/folder_library.dart';
import 'package:photobridge/core/identity.dart';
import 'package:photobridge/core/protocol.dart';
import 'package:photobridge/core/scanner.dart';
import 'package:photobridge/core/server.dart';
import 'package:photobridge/core/settings.dart';

/// One side's identity, trust list and pairing code.
class TestDevice {
  TestDevice(this.id, this.code);

  final String id;
  String code;
  late DeviceIdentity identity;
  final trusted = <String, TrustedDevice>{};

  static Future<TestDevice> make(String id, String code) async =>
      TestDevice(id, code)
        ..identity = await DeviceIdentity.fromSeed(DeviceIdentity.newSeed());

  /// Few PBKDF2 rounds keep tests fast; the app uses 600k.
  Future<List<int>> stretched() => CodeSecret.stretch(code, iterations: 10);

  Future<void> onPaired(String id, String name, List<int> pub) async =>
      trusted[id] = (publicKey: pub, name: name);

  PeerClient client({int? port}) => PeerClient(
    selfId: id,
    selfName: () => id,
    identity: identity,
    trusted: (i) => trusted[i],
    pairingCode: stretched,
    onPaired: onPaired,
    selfPort: port == null ? null : () => port,
  );
}

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
    final incoming = <IncomingFile>[];
    final receiving = <(int, int, bool)>[];
    final contacts = <(String, String, int)>[];
    late TestDevice recv;
    late TestDevice sender;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pb');
      received.clear();
      incoming.clear();
      receiving.clear();
      contacts.clear();
      have.clear();
      recv = await TestDevice.make('recv', 'SECRET12');
      sender = await TestDevice.make('send', 'SECRET12');
      server = ReceiveServer(
        selfInfo: () => {'id': 'recv', 'name': 'Pixel', 'os': 'android'},
        identity: recv.identity,
        trusted: (id) => recv.trusted[id],
        pairingCode: recv.stretched,
        onPaired: recv.onPaired,
        alreadyHave: (s, a) async => have.contains('$s|$a'),
        onFile: (f) async {
          received[f.name] = await f.file.readAsBytes();
          incoming.add(f);
          have.add('${f.senderId}|${f.assetId}');
          if (f.kind == 'file') return;
          expect(f.kind, 'video');
          expect(f.created, DateTime.fromMillisecondsSinceEpoch(1700000000000));
          expect(f.location, (12.9716, 77.5946));
        },
        onReceiving: (_, _, _, got, total, {done = false}) =>
            receiving.add((got, total, done)),
        onContact: (id, host, port) => contacts.add((id, host, port)),
        tempRoot: tmp,
      );
      await server.start();
      client = sender.client(port: 4242);
    });

    tearDown(() async {
      client.close();
      await server.stop();
      await tmp.delete(recursive: true);
    });

    test(
      'pairs once, uploads, dedupes; unpaired devices are refused',
      () async {
        final info = await client.probe('127.0.0.1', server.port);
        expect(info!.id, 'recv');
        expect(info.paired, isTrue);
        // SPAKE2 swapped identity keys both ways.
        expect(recv.trusted['send']!.publicKey, sender.identity.publicKey);
        expect(sender.trusted['recv']!.publicKey, recv.identity.publicKey);
        // The receiver learns where to reach the caller back.
        expect(contacts.last, ('send', '127.0.0.1', 4242));
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
          location: (12.9716, 77.5946),
          onProgress: (s, _) => lastProgress = s,
        );

        expect(await client.has(peer, 'A1'), isFalse);
        expect(await send(), 'saved');
        expect(lastProgress, src.lengthSync());
        // The receiver counted every byte, then reported the end once.
        final size = src.lengthSync();
        expect(receiving.last, (size, size, true));
        expect(receiving.where((r) => r.$3), hasLength(1));
        expect(receiving.length, greaterThan(2));
        expect(received['Trip clip #1.MOV'], src.readAsBytesSync());
        expect(await client.has(peer, 'A1'), isTrue);
        expect(await send(), 'duplicate');
        // Staging folder is cleaned up after each upload.
        expect(Directory('${tmp.path}/incoming').listSync(), isEmpty);

        // The code isn't needed any more once paired.
        sender.code = 'CHANGED1';
        expect((await client.probe('127.0.0.1', server.port))!.paired, isTrue);
        // The receiver restarts and forgets our session: we start a new one.
        server.dropSessions();
        expect(await client.has(peer, 'A1'), isTrue);

        // Unpaired (forgotten) with a different code: refused.
        recv.trusted.clear();
        server.dropSessions();
        client.dropSessions();
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
      },
    );

    test('an interrupted upload resumes where it stopped', () async {
      final info = await client.probe('127.0.0.1', server.port);
      final peer = Peer(info!, '127.0.0.1', server.port);
      final src = File('${tmp.path}/big.mov')
        ..writeAsBytesSync(List.generate(5 * kChunkSize + 123, (i) => i % 241));
      Future<String> send({int? failAt}) => client.upload(
        peer,
        assetId: 'BIG',
        file: src,
        name: 'big.mov',
        kind: 'video',
        created: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        location: (12.9716, 77.5946),
        onProgress: (sent, _) {
          if (failAt != null && sent >= failAt) throw StateError('drop');
        },
      );

      await expectLater(send(failAt: 3 * kChunkSize), throwsA(anything));
      // Let the receiver notice the dropped connection.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await client.status(peer, 'BIG')).offset, greaterThan(0));
      receiving.clear();
      expect(await send(), 'saved');
      // The second attempt didn't start from zero.
      expect(receiving.first.$1, greaterThan(kChunkSize));
      expect(received['big.mov'], src.readAsBytesSync());
    });

    test(
      'wrong codes get locked out; unsigned replies are untrusted',
      () async {
        sender.code = 'WRONG999';
        for (var i = 0; i < 10; i++) {
          client.dropSessions(); // skip the client's own back-off
          expect(
            (await client.probe('127.0.0.1', server.port))!.paired,
            isFalse,
          );
        }
        // Locked out now, even with the right code, for a minute.
        sender.code = 'SECRET12';
        client.dropSessions();
        expect(await client.probe('127.0.0.1', server.port), isNull);
        expect(recv.trusted, isEmpty);
      },
    );

    test('files keep their folder, which cannot escape', () async {
      final info = await client.probe('127.0.0.1', server.port);
      final peer = Peer(info!, '127.0.0.1', server.port);
      final src = File('${tmp.path}/notes.pdf')..writeAsStringSync('%PDF');
      Future<String> send(String dir) => client.upload(
        peer,
        assetId: 'file:1:$dir',
        file: src,
        name: 'notes.pdf',
        kind: 'file',
        dir: dir,
        created: DateTime(2026),
      );

      expect(await send('Trip/Day 1'), 'saved');
      expect(await send('../../etc/.ssh'), 'saved');
      expect(incoming.map((f) => (f.kind, f.dir, f.name)), [
        ('file', 'Trip/Day 1', 'notes.pdf'),
        ('file', 'etc', 'notes.pdf'),
      ]);
      expect(received['notes.pdf'], src.readAsBytesSync());
    });
  });

  test('safeDir drops traversal, absolute and hidden parts', () {
    expect(ReceiveServer.safeDir('/a/./b/../c:d/'), 'a/b/c_d');
    expect(ReceiveServer.safeDir(r'x\\y'), 'x/y');
    expect(ReceiveServer.safeDir(''), '');
  });

  test('inbound off rejects photos but still takes files', () async {
    final tmp = await Directory.systemTemp.createTemp('pb');
    final got = <String>[];
    final mac = await TestDevice.make('mac', 'SECRET12');
    final phone = await TestDevice.make('send', 'SECRET12');
    final server = ReceiveServer(
      selfInfo: () => {
        'id': 'mac',
        'name': 'Mac',
        'os': 'macos',
        'inbound': false,
      },
      identity: mac.identity,
      trusted: (id) => mac.trusted[id],
      pairingCode: mac.stretched,
      onPaired: mac.onPaired,
      alreadyHave: (_, _) async => false,
      acceptsPhotos: () => false,
      onFile: (f) async => got.add(f.kind),
      tempRoot: tmp,
    );
    await server.start();
    final client = phone.client();
    try {
      final info = await client.probe('127.0.0.1', server.port);
      expect(info!.inbound, isFalse);
      final peer = Peer(info, '127.0.0.1', server.port);
      final src = File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      Future<String> send(String kind, String id) => client.upload(
        peer,
        assetId: id,
        file: src,
        name: 'a.jpg',
        kind: kind,
        created: DateTime(2026),
      );
      await expectLater(
        send('image', 'P1'),
        throwsA(
          isA<TransferException>().having(
            (e) => e.rejected,
            'rejected',
            isTrue,
          ),
        ),
      );
      expect(await send('file', 'F1'), 'saved');
      expect(got, ['file']);
    } finally {
      client.close();
      await server.stop();
      await tmp.delete(recursive: true);
    }
  });

  test(
    'Mac folder library lists media and saves with the taken date',
    () async {
      final root = await Directory.systemTemp.createTemp('pbfolder');
      try {
        final lib = FolderLibrary(() => root.path);
        File('${root.path}/b.JPG').writeAsBytesSync([1]);
        Directory('${root.path}/Trip').createSync();
        File('${root.path}/Trip/c.mov').writeAsBytesSync([1]);
        File('${root.path}/notes.txt').writeAsBytesSync([1]);
        Directory('${root.path}/.hidden').createSync();
        File('${root.path}/.hidden/d.jpg').writeAsBytesSync([1]);

        final all = await lib.pending(
          since: DateTime(2100),
          includeVideos: true,
        );
        expect(all.map((i) => i.title).toSet(), {'b.JPG', 'c.mov'});
        final photos = await lib.pending(
          since: DateTime(2100),
          includeVideos: false,
        );
        expect(photos.map((i) => i.title), ['b.JPG']);

        final incoming = File('${root.path}/../in-${root.path.hashCode}.jpg')
          ..writeAsBytesSync([9]);
        final taken = DateTime(2024, 5, 1, 10, 30);
        final id = await lib.save(
          incoming,
          name: 'b.JPG',
          kind: 'image',
          created: taken,
        );
        expect(id, '${root.path}/b (1).JPG');
        expect(File(id).lastModifiedSync(), taken);
        incoming.deleteSync();
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('Mac folders become albums; dates are repaired by name', () async {
    final root = await Directory.systemTemp.createTemp('pbalbum');
    try {
      final lib = FolderLibrary(() => root.path);
      Directory('${root.path}/Goa trip').createSync();
      final inAlbum = File('${root.path}/Goa trip/a.jpg')
        ..writeAsBytesSync([1]);
      final loose = File('${root.path}/b.jpg')..writeAsBytesSync([1]);
      expect(await lib.albumsFor({inAlbum.path, loose.path}), {
        inAlbum.path: 'Goa trip',
      });

      final taken = DateTime(2025, 12, 24, 18, 5);
      final fixed = await lib.repairDates([
        (name: 'A.JPG', created: taken, location: null),
        (name: 'missing.jpg', created: taken, location: null),
      ]);
      expect(fixed, 1);
      expect(inAlbum.lastModifiedSync(), taken);
      // Saving into an album makes the folder.
      final src = File('${root.path}/../src-${root.path.hashCode}.jpg')
        ..writeAsBytesSync([2]);
      final id = await lib.save(
        src,
        name: 'c.jpg',
        kind: 'image',
        album: 'Goa trip',
      );
      expect(id, '${root.path}/Goa trip/c.jpg');
      src.deleteSync();
    } finally {
      await root.delete(recursive: true);
    }
  });
}
