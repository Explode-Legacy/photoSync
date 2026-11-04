import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Keys for one secure channel between two devices: a signing key for
/// requests and replies, and an encryption key from which each request
/// derives its own AES-256-GCM key using a random salt.
///
/// Made from a session secret (see identity.dart): fresh every few minutes,
/// from throwaway keys, so old traffic stays private even if a device's
/// long-term key or the pairing code leaks later.
class ChannelKeys {
  ChannelKeys._(this._authKey, this._encKey);

  final SecretKey _authKey;
  final SecretKey _encKey;

  static Future<ChannelKeys> fromSecret(List<int> secret) async {
    final master = SecretKey(secret);
    Future<SecretKey> sub(String info) => _hkdf.deriveKey(
      secretKey: master,
      nonce: const <int>[],
      info: utf8.encode(info),
    );
    return ChannelKeys._(await sub('pb3/auth'), await sub('pb3/enc'));
  }

  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _hmac = Hmac.sha256();

  Future<String> sign(String message) async {
    final mac = await _hmac.calculateMac(
      utf8.encode(message),
      secretKey: _authKey,
    );
    return base64Url.encode(mac.bytes);
  }

  Future<bool> verify(String message, String signature) async =>
      constantTimeEquals(
        utf8.encode(await sign(message)),
        utf8.encode(signature),
      );

  /// The AES-256-GCM key for one request, from its random [salt].
  Future<Sealer> sealer(List<int> salt) async => Sealer(
    await _hkdf.deriveKey(secretKey: _encKey, nonce: salt, info: _info),
  );

  static final _info = utf8.encode('pb3/transfer');
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The pairing code, stretched with PBKDF2 (600,000 rounds), for SPAKE2.
/// Only used while pairing two devices; never for traffic.
abstract final class CodeSecret {
  static const defaultIterations = 600000;
  static final _cache = <String, Future<List<int>>>{};

  static Future<List<int>> stretch(
    String code, {
    int iterations = defaultIterations,
  }) => _cache.putIfAbsent('$iterations:$code', () async {
    // Android has a native PBKDF2. Elsewhere it's pure Dart and takes
    // seconds: run it off the UI isolate so the app (and its server) stay
    // responsive meanwhile.
    if (Platform.isAndroid) return _stretch(code, iterations, Pbkdf2.new);
    return Isolate.run(() => _stretch(code, iterations, DartPbkdf2.new));
  });

  static Future<List<int>> _stretch(
    String code,
    int iterations,
    Pbkdf2 Function({
      required MacAlgorithm macAlgorithm,
      required int iterations,
      required int bits,
    })
    make,
  ) async {
    final key =
        await make(
          macAlgorithm: Hmac.sha256(),
          iterations: iterations,
          bits: 320,
        ).deriveKeyFromPassword(
          password: code,
          nonce: utf8.encode('photobridge/v3/pairing'),
        );
    return key.extractBytes();
  }
}

/// Random bytes, base64url-encoded (salts and request nonces).
String randomToken([int bytes = 16]) {
  final r = Random.secure();
  return base64Url.encode(List.generate(bytes, (_) => r.nextInt(256)));
}

/// Plaintext bytes per encrypted chunk. Resumes restart at a chunk boundary.
const kChunkSize = 1 << 20;
const _tagSize = 16;
const _lengthSize = 4;

/// Encrypted size of [plainLength] bytes: each chunk gets a 4-byte length
/// prefix and a 16-byte tag; an empty file is one empty chunk.
int sealedLength(int plainLength) {
  final chunks = max(1, (plainLength + kChunkSize - 1) ~/ kChunkSize);
  return plainLength + chunks * (_lengthSize + _tagSize);
}

/// AES-256-GCM with a per-request key. Chunk `i` uses nonce
/// `00000000 || i (8 bytes)`, and the "last chunk" flag is authenticated,
/// so chunks can't be reordered, dropped or cut off without detection.
class Sealer {
  Sealer(this._key);

  final SecretKey _key;
  static final _aes = AesGcm.with256bits();

  /// Index used for the request's metadata, never for a file chunk.
  static const _metaIndex = 0x7fffffffffffffff;

  static List<int> _nonce(int index) {
    final b = ByteData(12)..setInt64(4, index);
    return b.buffer.asUint8List();
  }

  Future<List<int>> seal(
    List<int> plain,
    int index, {
    required bool last,
  }) async {
    final box = await _aes.encrypt(
      plain,
      secretKey: _key,
      nonce: _nonce(index),
      aad: [last ? 1 : 0],
    );
    return [...box.cipherText, ...box.mac.bytes];
  }

  Future<List<int>> open(
    List<int> sealed,
    int index, {
    required bool last,
  }) async {
    if (sealed.length < _tagSize) {
      throw const CryptoException('Chunk too short');
    }
    final split = sealed.length - _tagSize;
    try {
      return await _aes.decrypt(
        SecretBox(
          sealed.sublist(0, split),
          nonce: _nonce(index),
          mac: Mac(sealed.sublist(split)),
        ),
        secretKey: _key,
        aad: [last ? 1 : 0],
      );
    } on SecretBoxAuthenticationError {
      throw const CryptoException('altered, out of order or wrong key');
    }
  }

  /// Encrypts a small JSON value for a header.
  Future<String> sealJson(Object value) async => base64Url.encode(
    await seal(utf8.encode(jsonEncode(value)), _metaIndex, last: true),
  );

  Future<Map<String, dynamic>> openJson(String sealed) async {
    final plain = await open(base64Url.decode(sealed), _metaIndex, last: true);
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  /// Encrypts [file] from [offset] (a multiple of [kChunkSize]) as length-
  /// prefixed chunks. [onPlain] reports plaintext bytes read so far,
  /// counting from the start of the file.
  Stream<List<int>> sealFile(
    File file, {
    int offset = 0,
    void Function(int plainBytes)? onPlain,
  }) async* {
    assert(offset % kChunkSize == 0);
    final length = await file.length();
    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      var pos = offset;
      var index = offset ~/ kChunkSize;
      do {
        final chunk = await raf.read(min(kChunkSize, length - pos));
        pos += chunk.length;
        final last = pos >= length;
        final sealed = await seal(chunk, index++, last: last);
        yield (ByteData(
          _lengthSize,
        )..setUint32(0, sealed.length)).buffer.asUint8List();
        yield sealed;
        onPlain?.call(pos);
        if (last) break;
      } while (true);
    } finally {
      await raf.close();
    }
  }

  /// Encrypts bytes in memory the same way (for request bodies).
  Stream<List<int>> sealBytes(List<int> data) async* {
    var index = 0;
    var pos = 0;
    do {
      final end = min(pos + kChunkSize, data.length);
      final last = end >= data.length;
      final sealed = await seal(data.sublist(pos, end), index++, last: last);
      yield (ByteData(
        _lengthSize,
      )..setUint32(0, sealed.length)).buffer.asUint8List();
      yield sealed;
      pos = end;
      if (last) break;
    } while (true);
  }

  /// Decrypts a stream from [sealFile], starting at chunk [firstIndex].
  /// Throws [CryptoException] if anything was altered, reordered or cut off.
  Stream<List<int>> openStream(
    Stream<List<int>> input, {
    int firstIndex = 0,
  }) async* {
    const full = kChunkSize + _tagSize;
    final buf = BytesBuilder(copy: false);
    var need = _lengthSize; // bytes required before parsing is worthwhile
    var index = firstIndex;
    var sawLast = false;
    // A full-size chunk is the last one only if nothing follows it, which
    // we only learn from what comes next.
    Uint8List? pending;

    await for (final data in input) {
      if (sawLast) throw const CryptoException('Data after the last chunk');
      buf.add(data);
      if (buf.length < need) continue;
      final bytes = buf.takeBytes();
      var off = 0;
      while (bytes.length - off >= _lengthSize) {
        final len = ByteData.sublistView(
          bytes,
          off,
          off + _lengthSize,
        ).getUint32(0);
        if (len > full || len < _tagSize) {
          throw const CryptoException('Bad chunk length');
        }
        if (bytes.length - off - _lengthSize < len) break;
        final chunk = Uint8List.sublistView(
          bytes,
          off + _lengthSize,
          off + _lengthSize + len,
        );
        off += _lengthSize + len;
        if (pending != null) {
          yield await open(pending, index++, last: false);
          pending = null;
        }
        if (len < full) {
          yield await open(chunk, index++, last: true);
          sawLast = true;
          if (off < bytes.length) {
            throw const CryptoException('Data after the last chunk');
          }
          break;
        }
        pending = chunk;
      }
      final rest = bytes.length - off;
      if (rest > 0) buf.add(Uint8List.sublistView(bytes, off));
      need = rest >= _lengthSize
          ? _lengthSize +
                ByteData.sublistView(bytes, off, off + _lengthSize).getUint32(0)
          : _lengthSize;
    }
    if (pending != null) {
      yield await open(pending, index++, last: true);
      sawLast = true;
    }
    if (!sawLast) throw const CryptoException('Transfer was cut off');
    if (buf.length > 0) throw const CryptoException('Trailing bytes');
  }
}

/// The data didn't decrypt: wrong key, or altered, reordered or cut off.
class CryptoException implements Exception {
  const CryptoException(this.message);

  final String message;

  @override
  String toString() => 'Encryption check failed: $message';
}
