import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// رمز الوالد المحلي: يحمي إيقاف Kiosk وفك الاقتران على جهاز الطفل.
/// يُخزَّن مجزَّأً (SHA-256 + salt) ولا يُرسل لأي سيرفر.
class ParentPin {
  ParentPin._();

  static const _kHash = 'parent_pin_hash';
  static const _kSalt = 'parent_pin_salt';
  static const int maxFailures = 5;
  static const Duration lockDuration = Duration(seconds: 60);

  static int _failures = 0;
  static DateTime? _lockedUntil;

  static Future<bool> isSet() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_kHash) ?? '').isNotEmpty;
  }

  static bool isValidFormat(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  static Future<void> set(String pin) async {
    final rnd = Random.secure();
    final salt = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSalt, salt);
    await p.setString(_kHash, _hash(salt, pin));
    _failures = 0;
    _lockedUntil = null;
  }

  /// المدة المتبقية للقفل المؤقت بعد محاولات خاطئة كثيرة (أو null).
  static Duration? lockRemaining() {
    final until = _lockedUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left.isNegative) {
      _lockedUntil = null;
      _failures = 0;
      return null;
    }
    return left;
  }

  static Future<bool> verify(String pin) async {
    if (lockRemaining() != null) return false;
    final p = await SharedPreferences.getInstance();
    final salt = p.getString(_kSalt) ?? '';
    final hash = p.getString(_kHash) ?? '';
    if (hash.isEmpty) return true;
    final ok = _constEq(_hash(salt, pin), hash);
    if (ok) {
      _failures = 0;
      return true;
    }
    _failures++;
    if (_failures >= maxFailures) {
      _lockedUntil = DateTime.now().add(lockDuration);
    }
    return false;
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kHash);
    await p.remove(_kSalt);
    _failures = 0;
    _lockedUntil = null;
  }

  static String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }
}
