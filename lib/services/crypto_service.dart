import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:crypto/crypto.dart' as crypto_lib;

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
    // HKDF-SHA256: extract + expand
    final inputKey = Uint8List.fromList(utf8.encode(adminToken));
    const info = 'camera_parent_files_e2e_v1';
    const salt = 'hkdf_salt_v1';
    
    // Extract: PRK = HMAC-Hash(salt, IKM)
    final extractor = pc.HMac(pc.SHA256Digest(), 64)
      ..init(pc.KeyParameter(Uint8List.fromList(utf8.encode(salt))));
    extractor.update(inputKey, 0, inputKey.length);
    final prk = Uint8List(32);
    extractor.doFinal(prk, 0);
    
    // Expand: OKM = HMAC-Hash(PRK, info || counter)
    final expander = pc.HMac(pc.SHA256Digest(), 64)
      ..init(pc.KeyParameter(prk));
    expander.update(Uint8List.fromList(utf8.encode(info)), 0, info.length);
    expander.updateByte(0x01); // counter = 1
    final okm = Uint8List(32);
    expander.doFinal(okm, 0);
    
    return okm;
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