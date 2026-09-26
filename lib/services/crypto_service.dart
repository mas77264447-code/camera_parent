import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  Uint8List? _derivedKey;

  void initialize(String adminToken) {
    _derivedKey = _deriveKey(adminToken);
    print('[Crypto] initialized, key length=${_derivedKey!.length}');
  }

  bool get isInitialized => _derivedKey != null;

  Uint8List _deriveKey(String adminToken) {
    final inputKey = Uint8List.fromList(utf8.encode(adminToken));
    final info = Uint8List.fromList(utf8.encode('camera_parent_files_v1'));
    final salt = Uint8List.fromList(utf8.encode('camera_parent_files_salt'));

    final hmac = pc.HMac(pc.SHA256Digest(), 64)
      ..init(pc.KeyParameter(inputKey));

    hmac.update(salt, 0, salt.length);
    hmac.update(inputKey, 0, inputKey.length);
    hmac.update(info, 0, info.length);

    final out = Uint8List(32);
    hmac.doFinal(out, 0);
    return out;
  }

  Uint8List encrypt(Uint8List plaintext) {
    if (_derivedKey == null) {
      throw StateError('CryptoService not initialized');
    }

    final nonce = _randomBytes(12);
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final params = pc.AEADParameters(
      pc.KeyParameter(_derivedKey!),
      128,
      nonce,
      Uint8List(0),
    );

    cipher.init(true, params);
    final encrypted = cipher.process(plaintext);
    final tag = cipher.mac;

    final result = BytesBuilder();
    result.add(nonce);
    result.add(encrypted);
    result.add(tag);
    return result.toBytes();
  }

  Uint8List decrypt(Uint8List ciphertext) {
    if (_derivedKey == null) {
      throw StateError('CryptoService not initialized');
    }
    if (ciphertext.length < 28) {
      throw ArgumentError('Ciphertext too short');
    }

    final nonce = ciphertext.sublist(0, 12);
    final tag = ciphertext.sublist(ciphertext.length - 16);
    final encrypted = ciphertext.sublist(12, ciphertext.length - 16);

    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final params = pc.AEADParameters(
      pc.KeyParameter(_derivedKey!),
      128,
      nonce,
      Uint8List(0),
    );

    cipher.init(false, params);
    final decrypted = cipher.process(encrypted);

    final computedTag = cipher.mac;
    if (!_constantTimeEquals(computedTag, tag)) {
      throw StateError('Tag mismatch');
    }
    return decrypted;
  }

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  void clear() {
    _derivedKey = null;
    print('[Crypto] cleared');
  }
}