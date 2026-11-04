import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photobridge/core/crypto.dart';

void main() {
  test('32 zero bytes of salt give the same keys as an empty salt', () async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final secret = SecretKey(List.generate(32, (i) => i));
    Future<List<int>> derive(List<int> salt) async => (await hkdf.deriveKey(
      secretKey: secret,
      nonce: salt,
      info: utf8.encode('pb3/auth'),
    )).extractBytes();
    // Devices on 1.4.0 used an empty salt; 1.4.1 must agree with them.
    expect(await derive(hkdfNoSalt), await derive(const []));
  });
}
