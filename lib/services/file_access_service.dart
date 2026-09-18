import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// خدمة الوصول للملفات — على جهاز الطفل.
/// تتصل بـ FileAccessPlugin.kt عبر MethodChannel.
class FileAccessService {
  FileAccessService._();
  static final FileAccessService instance = FileAccessService._();

  static const _channel = MethodChannel('camera_parent/file_access');

  /// هل التطبيق يملك صلاحية الوصول للتخزين؟
  Future<bool> hasStoragePermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasStoragePermission') ?? false;
    } catch (e) {
      debugPrint('[FileAccess] hasStoragePermission: $e');
      return false;
    }
  }

  /// عرض قائمة من المعرض (صور/فيديو/صوت).
  Future<List<Map<String, dynamic>>> listGallery({
    String type = 'image',
    int limit = 500,
  }) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'listGallery',
        {'type': type, 'limit': limit},
      );
      if (result == null) return [];
      return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('[FileAccess] listGallery: $e');
      return [];
    }
  }

  /// عرض محتوى مجلد في نظام الملفات.
  Future<Map<String, dynamic>?> listDirectory({String? path}) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'listDirectory',
        {'path': path},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('[FileAccess] listDirectory: $e');
      return null;
    }
  }

  /// معلومات ملف (الاسم + الحجم).
  Future<Map<String, dynamic>?> getFileInfo(String uri) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getFileInfo',
        {'uri': uri},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('[FileAccess] getFileInfo: $e');
      return null;
    }
  }

  /// قراءة قطعة من الملف (Base64) — للبث على chunks.
  Future<Map<String, dynamic>?> readFileChunk({
    required String uri,
    required int offset,
    int length = 65536,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readFileChunk',
        {'uri': uri, 'offset': offset, 'length': length},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('[FileAccess] readFileChunk: $e');
      return null;
    }
  }

  /// قراءة ملف كامل وإرجاعه كـ Uint8List (للصور الصغيرة).
  Future<Uint8List?> readFileBytes(String uri, {int maxBytes = 5 * 1024 * 1024}) async {
    final info = await getFileInfo(uri);
    final size = (info?['size'] as num?)?.toInt() ?? 0;
    if (size > maxBytes) {
      debugPrint('[FileAccess] file too large: $size bytes');
      return null;
    }

    final buffer = BytesBuilder();
    int offset = 0;
    const chunkSize = 65536;

    while (true) {
      final chunk = await readFileChunk(
        uri: uri,
        offset: offset,
        length: chunkSize,
      );
      if (chunk == null) break;

      final data = chunk['data'] as String?;
      if (data == null || data.isEmpty) break;

      buffer.add(base64Decode(data));
      offset += chunkSize;

      if (chunk['eof'] == true) break;
    }

    return buffer.toBytes();
  }
}
