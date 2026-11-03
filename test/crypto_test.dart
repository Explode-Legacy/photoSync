import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/crypto.dart';

void main() {
  // Few PBKDF2 rounds keep the tests fast; the app uses 600k.
  Future<PairKeys> keys(String code) => PairKeys.forCode(code, iterations: 10);

  test('signatures check the code', () async {
    final a = await keys('ABCD2345');
    final b = await keys('WRONG999');
    final sig = await a.sign('GET /info');
    expect(await a.verify('GET /info', sig), isTrue);
    expect(await b.verify('GET /info', sig), isFalse);
    expect(await a.verify('GET /has', sig), isFalse);
  });

  group('sealed streams', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('pbc'));
    tearDown(() => tmp.delete(recursive: true));

    Future<(List<int>, String)> roundTrip(int size, {int offset = 0}) async {
      final data = Uint8List.fromList(List.generate(size, (i) => i * 7 % 251));
      final f = File('${tmp.path}/f')..writeAsBytesSync(data);
      final k = await keys('ABCD2345');
      final salt = randomToken();
      final sealed = await (await k.sealer(salt.codeUnits))
          .sealFile(f, offset: offset)
          .expand((c) => c)
          .toList();
      expect(sealed.length, sealedLength(size - offset));
      // Deliver in awkward pieces, like a network would.
      Stream<List<int>> pieces() async* {
        for (var i = 0; i < sealed.length; i += 70001) {
          yield sealed.sublist(i, (i + 70001).clamp(0, sealed.length));
        }
      }

      final opened = await (await k.sealer(salt.codeUnits))
          .openStream(pieces(), firstIndex: offset ~/ kChunkSize)
          .expand((c) => c)
          .toList();
      expect(opened, data.sublist(offset));
      return (sealed, salt);
    }

    test('empty, small, exact and multi-chunk files', () async {
      await roundTrip(0);
      await roundTrip(1000);
      await roundTrip(kChunkSize);
      await roundTrip(kChunkSize * 2 + 5);
    });

    test('resumes from a chunk boundary', () async {
      await roundTrip(kChunkSize * 3 + 10, offset: kChunkSize * 2);
    });

    test('detects tampering and truncation', () async {
      final (sealed, salt) = await roundTrip(kChunkSize + 100);
      final k = await keys('ABCD2345');
      Future<void> open(List<int> bytes) async {
        await (await k.sealer(salt.codeUnits))
            .openStream(Stream.value(bytes))
            .drain<void>();
      }

      await open(sealed); // intact: fine
      final flipped = [...sealed]..[100] ^= 1;
      await expectLater(open(flipped), throwsA(isA<Object>()));

      // Dropping the last chunk must not look like a complete file.
      final cut = sealed.sublist(0, 4 + kChunkSize + 16);
      await expectLater(open(cut), throwsA(isA<CryptoException>()));
      // Swapping chunk order fails too.
      final first = sealed.sublist(0, 4 + kChunkSize + 16);
      final second = sealed.sublist(4 + kChunkSize + 16);
      await expectLater(open([...second, ...first]), throwsA(isA<Object>()));
    });
  });

  test('json metadata round trip', () async {
    final s = await (await keys('ABCD2345')).sealer([1, 2, 3]);
    final sealed = await s.sealJson({'name': 'IMG_1.HEIC', 'lat': 12.5});
    expect(await s.openJson(sealed), {'name': 'IMG_1.HEIC', 'lat': 12.5});
  });
}
