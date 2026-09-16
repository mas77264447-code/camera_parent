import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores authentication credentials encrypted with an Android Keystore key.
/// A one-time migration reads legacy SharedPreferences values and moves them
/// into the secure store, then removes the plaintext copies.
class SecureStore {
  static const MethodChannel _channel =
      MethodChannel('camera_parent/secure_store');

  static Future<String?> read(String key) async {
    final value = await _channel.invokeMethod<String>('get', {'key': key});
    if (value != null && value.isNotEmpty) return value;

    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(key);
    if (legacy == null || legacy.isEmpty) return null;

    await write(key, legacy);
    await prefs.remove(key);
    return legacy;
  }

  static Future<void> write(String key, String value) async {
    await _channel.invokeMethod<bool>('set', {
      'key': key,
      'value': value,
    });
  }

  static Future<void> delete(String key) async {
    await _channel.invokeMethod<bool>('delete', {'key': key});
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}
