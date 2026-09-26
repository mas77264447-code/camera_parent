import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FileAccessService {
  FileAccessService._();
  static final FileAccessService instance = FileAccessService._();

  static const _channel = MethodChannel('camera_parent/file_access');

  Future<bool> hasStoragePermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasStoragePermission') ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> openAllFilesSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAllFilesSettings') ?? false;
    } catch (e) {
      return false;
    }
  }

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

  Future<Map<String, dynamic>?> getFileInfo(String uri) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getFileInfo',
        {'uri': uri},
      );
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      return null;
    }
  }

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
      return null;
    }
  }

  Future<Uint8List?> readFileBytes(String uri, {int maxBytes = 5 * 1024 * 1024}) async {
    final info = await getFileInfo(uri);
    final size = (info?['size'] as num?)?.toInt() ?? 0;
    if (size > maxBytes) return null;

    final buffer = BytesBuilder();
    int offset = 0;
    const chunkSize = 65536;

    while (true) {
      final chunk = await readFileChunk(
        uri: uri, offset: offset, length: chunkSize,
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