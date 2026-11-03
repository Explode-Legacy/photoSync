import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/crypto.dart';
import 'package:photobridge/core/identity.dart';

void main() {
  Future<List<int>> code(String c) => CodeSecret.stretch(c, iterations: 10);

  test(
    'SPAKE2: same code gives the same key, a different one does not',
    () async {
      final a = Spake2.start(await code('ABCD2345'), initiator: true);
      final b = Spake2.start(await code('ABCD2345'), initiator: false);
      expect(a.sharedKey(b.message), b.sharedKey(a.message));

      final wrong = Spake2.start(await code('WRONG999'), initiator: false);
      expect(a.sharedKey(wrong.message), isNot(wrong.sharedKey(a.message)));
    },
  );

  test('SPAKE2 rejects garbage points', () async {
    final a = Spake2.start(await code('ABCD2345'), initiator: true);
    // Uncompressed points (which might be off the curve) are refused.
    expect(
      () => a.sharedKey([4, ...List.filled(64, 1)]),
      throwsA(isA<CryptoException>()),
    );
    expect(() => a.sharedKey([1, 2, 3]), throwsA(isA<CryptoException>()));
  });

  test('pairing confirmations match only with the same transcript', () async {
    List<int> tt(List<int> k) => pairingTranscript(
      idA: 'a',
      pubA: [1],
      idB: 'b',
      pubB: [2],
      shareA: [3],
      shareB: [4],
      k: k,
      w: [5],
    );
    expect(
      await pairingConfirm(tt([9]), 'A'),
      await pairingConfirm(tt([9]), 'A'),
    );
    expect(
      await pairingConfirm(tt([9]), 'A'),
      isNot(await pairingConfirm(tt([9]), 'B')),
    );
    expect(
      await pairingConfirm(tt([9]), 'A'),
      isNot(await pairingConfirm(tt([8]), 'A')),
    );
  });

  test('Noise KK: both sides agree, a stranger does not', () async {
    final i = await DeviceIdentity.fromSeed(DeviceIdentity.newSeed());
    final r = await DeviceIdentity.fromSeed(DeviceIdentity.newSeed());
    final eve = await DeviceIdentity.fromSeed(DeviceIdentity.newSeed());
    final ei = await newEphemeral();
    final er = await newEphemeral();
    final eiPub = (await ei.extractPublicKey()).bytes;
    final erPub = (await er.extractPublicKey()).bytes;

    Future<(ChannelKeys, List<int>)> side(
      bool initiator,
      DeviceIdentity me,
      List<int> staticI,
    ) => kkSession(
      initiator: initiator,
      idI: 'i',
      idR: 'r',
      staticI: staticI,
      staticR: r.publicKey,
      ephemeralI: eiPub,
      ephemeralR: erPub,
      myStatic: me.keyPair,
      myEphemeral: initiator ? ei : er,
    );

    final (ki, hi) = await side(true, i, i.publicKey);
    final (kr, hr) = await side(false, r, i.publicKey);
    expect(hi, hr);
    final sig = await ki.sign('hello');
    expect(await kr.verify('hello', sig), isTrue);

    // Eve pretends to be i (claims i's public key) but lacks its private key.
    final (ke, _) = await side(true, eve, i.publicKey);
    expect(await kr.verify('hello', await ke.sign('hello')), isFalse);
  });

  test('fingerprints are short and stable', () async {
    final id = await DeviceIdentity.fromSeed(List.filled(32, 7));
    final fp = await fingerprint(id.publicKey);
    expect(fp, matches(RegExp(r'^[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}$')));
    expect(await fingerprint(id.publicKey), fp);
  });
}
