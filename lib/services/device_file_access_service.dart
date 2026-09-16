import 'dart:typed_data';

import 'package:flutter/services.dart';

/// الوصول إلى المجلد الذي اختاره صاحب جهاز Camera عبر نافذة Android الرسمية.
/// لا يتم تجاوز صلاحيات Android ولا يتم فتح ملفات خارج المجلد المصرح به.
class DeviceFileAccessService {
  static const MethodChannel _channel = MethodChannel('camera_parent/file_access');

  static Future<bool> hasFolderAccess() async {
    return await _channel.invokeMethod<bool>('hasFolderAccess') ?? false;
  }

  static Future<String?> requestFolderAccess() async {
    return await _channel.invokeMethod<String>('requestFolderAccess');
  }

  static Future<bool> releaseFolderAccess() async {
    return await _channel.invokeMethod<bool>('releaseFolderAccess') ?? false;
  }

  static Future<Uint8List?> readFile(String uri) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'readFile',
      <String, dynamic>{'uri': uri},
    );
    if (raw == null) return null;
    return Uint8List.fromList(List<int>.from(raw));
  }

  static Future<List<Map<String, dynamic>>> listFolder([String? uri]) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listFolder',
      uri == null ? null : <String, dynamic>{'uri': uri},
    );
    return (raw ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
