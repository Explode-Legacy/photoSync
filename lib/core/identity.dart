import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

import 'crypto.dart';

/// Signal-style trust for PhotoBridge, in three parts:
///
/// 1. **Identity.** Each device makes its own X25519 key pair on first run.
///    The private key never leaves it.
/// 2. **Pairing (SPAKE2, RFC 9382, P-256).** Two devices that know the same
///    pairing code prove it to each other and swap identity keys. A
///    recorded pairing can't be brute-forced offline: each guess needs a
///    live attempt, and those are rate-limited. After this the code is no
///    longer used.
/// 3. **Sessions (Noise "KK").** Each connection mixes fresh throwaway keys
///    with both identity keys. Sessions are replaced every few minutes and
///    their throwaway keys forgotten, so old traffic can't be decrypted
///    later, even with a device's identity key or the pairing code.

final _x25519 = X25519();
final _sha256 = Sha256();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _hmac = Hmac.sha256();

/// This device's long-term X25519 key pair.
class DeviceIdentity {
  DeviceIdentity._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final List<int> publicKey;

  /// [seed] is 32 random bytes, kept in the app's private storage.
  static Future<DeviceIdentity> fromSeed(List<int> seed) async {
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return DeviceIdentity._(kp, pub.bytes);
  }

  static List<int> newSeed() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256));
  }

  String get publicKeyText => base64Url.encode(publicKey);
}

/// Short, human-comparable form of a public key, e.g. "3F9A 1C42 7B0E".
Future<String> fingerprint(List<int> publicKey) async {
  final h = await _sha256.hash([...utf8.encode('pb3/fp'), ...publicKey]);
  final hex = h.bytes
      .take(6)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
      .join(' ');
}

// ------------------------------------------------------------------ SPAKE2

final _curve = ECCurve_secp256r1();
final _g = _curve.G;
final _n = _curve.n;

// RFC 9382 §6, P-256. Nobody knows their discrete logs relative to G.
final _m = _curve.curve.decodePoint(
  _hex('02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f'),
)!;
final _nPoint = _curve.curve.decodePoint(
  _hex('03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49'),
)!;

List<int> _hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

BigInt _toInt(List<int> bytes) =>
    bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));

BigInt _randomScalar() {
  final r = Random.secure();
  // 40 bytes reduced mod n: negligible bias.
  final v =
      _toInt(List.generate(40, (_) => r.nextInt(256))) % (_n - BigInt.one);
  return v + BigInt.one;
}

/// One side of a SPAKE2 exchange. The initiator (A) sends `T = w·M + x·G`,
/// the responder (B) `S = w·N + y·G`; both reach the same `K` only if they
/// used the same password scalar `w`.
class Spake2 {
  Spake2._(this._w, this._secret, this.isInitiator, this.message);

  final BigInt _w;
  final BigInt _secret;
  final bool isInitiator;

  /// Our public share (compressed point), to send to the other side.
  final Uint8List message;

  /// [stretchedCode] comes from [CodeSecret.stretch].
  factory Spake2.start(List<int> stretchedCode, {required bool initiator}) {
    final w = _toInt(stretchedCode) % _n;
    final x = _randomScalar();
    final share = ((initiator ? _m : _nPoint) * w)! + (_g * x)!;
    return Spake2._(w, x, initiator, share!.getEncoded(true));
  }

  /// The shared point `K`, from the other side's [peerMessage]. Throws
  /// [CryptoException] on a malformed or degenerate point.
  Uint8List sharedKey(List<int> peerMessage) {
    // Compressed points only: decoding one always yields a point on the
    // curve, which rules out invalid-curve attacks.
    if (peerMessage.length != 33 ||
        (peerMessage[0] != 2 && peerMessage[0] != 3)) {
      throw const CryptoException('Bad pairing message');
    }
    final ECPoint? peer;
    try {
      peer = _curve.curve.decodePoint(peerMessage);
    } catch (_) {
      throw const CryptoException('Bad pairing message');
    }
    if (peer == null || peer.isInfinity) {
      throw const CryptoException('Bad pairing message');
    }
    final unblinded = peer - ((isInitiator ? _nPoint : _m) * _w)!;
    final k = unblinded == null ? null : unblinded * _secret;
    if (k == null || k.isInfinity) {
      throw const CryptoException('Bad pairing message');
    }
    return k.getEncoded(true);
  }

  List<int> get wBytes => _bigToBytes(_w);
}

List<int> _bigToBytes(BigInt v) {
  final out = List<int>.filled(32, 0);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

/// Everything both sides must agree on: who is who, both identity keys,
/// both SPAKE2 shares, the shared point and the password scalar
/// (length-prefixed, as in RFC 9382).
List<int> pairingTranscript({
  required String idA,
  required List<int> pubA,
  required String idB,
  required List<int> pubB,
  required List<int> shareA,
  required List<int> shareB,
  required List<int> k,
  required List<int> w,
}) {
  final out = BytesBuilder();
  void add(List<int> part) {
    out.add(
      (ByteData(
        8,
      )..setUint64(0, part.length, Endian.little)).buffer.asUint8List(),
    );
    out.add(part);
  }

  add(utf8.encode('pb3/spake2'));
  add(utf8.encode(idA));
  add(pubA);
  add(utf8.encode(idB));
  add(pubB);
  add(shareA);
  add(shareB);
  add(k);
  add(w);
  return out.toBytes();
}

/// Confirmation MAC for [role] (`A` or `B`) over the transcript. Matching
/// MACs prove the other side used the same code and saw the same keys.
Future<String> pairingConfirm(List<int> transcript, String role) async {
  final digest = await _sha256.hash(transcript);
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(digest.bytes),
    nonce: const <int>[],
    info: utf8.encode('pb3/confirm/$role'),
  );
  final mac = await _hmac.calculateMac(transcript, secretKey: key);
  return base64Url.encode(mac.bytes);
}

// ---------------------------------------------------------------- sessions

/// A throwaway X25519 key pair for one session.
Future<SimpleKeyPair> newEphemeral() => _x25519.newKeyPair();

Future<List<int>> _dh(SimpleKeyPair mine, List<int> theirs) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
  );
  return shared.extractBytes();
}

/// Noise KK: initiator I and responder R know each other's identity keys
/// (from pairing). Each brings a throwaway key; the session secret mixes
/// ee, es, se and ss, so it needs both identities and both throwaways.
/// Returns the channel keys and a transcript hash both sides share.
Future<(ChannelKeys, List<int>)> kkSession({
  required bool initiator,
  required String idI,
  required String idR,
  required List<int> staticI,
  required List<int> staticR,
  required List<int> ephemeralI,
  required List<int> ephemeralR,
  required SimpleKeyPair myStatic,
  required SimpleKeyPair myEphemeral,
}) async {
  final h = (await _sha256.hash([
    ...utf8.encode('pb3/kk|$idI|$idR|'),
    ...staticI,
    ...staticR,
    ...ephemeralI,
    ...ephemeralR,
  ])).bytes;
  // Same four values on both sides, in the same order.
  final List<int> ee, es, se, ss;
  if (initiator) {
    ee = await _dh(myEphemeral, ephemeralR);
    es = await _dh(myEphemeral, staticR);
    se = await _dh(myStatic, ephemeralR);
    ss = await _dh(myStatic, staticR);
  } else {
    ee = await _dh(myEphemeral, ephemeralI);
    es = await _dh(myStatic, ephemeralI);
    se = await _dh(myEphemeral, staticI);
    ss = await _dh(myStatic, staticI);
  }
  final secret = await _hkdf.deriveKey(
    secretKey: SecretKey([...ee, ...es, ...se, ...ss]),
    nonce: h,
    info: utf8.encode('pb3/session'),
  );
  return (await ChannelKeys.fromSecret(await secret.extractBytes()), h);
}
