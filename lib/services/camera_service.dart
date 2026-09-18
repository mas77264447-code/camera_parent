import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class CameraService {
  static const String server =
      "https://camera-parent-server.onrender.com";

  static const Duration httpTimeout = Duration(seconds: 10);

  // ─── Parent account (username + password) ─────────────────

  /// إنشاء حساب والد جديد. يُرجع admin_token أو null.
  static Future<String?> parentRegister(
      String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse("$server/parent/register"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": username,
          "password": password,
        }),
      ).timeout(httpTimeout);

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        return body["data"]["admin_token"] as String?;
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('parentRegister error: $e');
      return null;
    }
  }

  /// تسجيل دخول والد موجود. يُرجع admin_token أو null.
  static Future<String?> parentLogin(
      String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse("$server/parent/login"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": username,
          "password": password,
        }),
      ).timeout(httpTimeout);

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        return body["data"]["admin_token"] as String?;
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('parentLogin error: $e');
      return null;
    }
  }

  // ─── Device management ────────────────────────────────────

  static Future<bool> forgetDevice(
      String sessionId, String adminToken) async {
    try {
      final response = await http.delete(
        Uri.parse("$server/camera/sessions/$sessionId"),
        headers: {"X-Admin-Token": adminToken},
      ).timeout(httpTimeout);

      return response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('Error: $e');
      return false;
    }
  }

  static Future<bool> verifyAdminToken(String adminToken) async {
    try {
      final response = await http.post(
        Uri.parse("$server/admin/verify"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"admin_token": adminToken}),
      ).timeout(httpTimeout);

      return response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('Error: $e');
      return false;
    }
  }

  static Future<bool> unpairDevice(String deviceToken) async {
    try {
      final response = await http.post(
        Uri.parse("$server/pairing/unpair"),
        headers: {"X-Device-Token": deviceToken},
      ).timeout(httpTimeout);

      return response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('Error: $e');
      return false;
    }
  }

  // ─── WebRTC media ─────────────────────────────────────────

  static Future<MediaStream> getUserMedia({
    bool audio = true,
    bool video = true,
    Map<String, dynamic>? videoConstraints,
  }) async {
    return await navigator.mediaDevices.getUserMedia({
      "audio": audio,
      "video": videoConstraints ?? video,
    });
  }

  // ✅ الإصلاح: fallback يحتوي STUN + TURN (كان STUN فقط)
  static const List<Map<String, dynamic>> _fallbackIceServers = [
    {"urls": "stun:stun.l.google.com:19302"},
    {"urls": "stun:stun1.l.google.com:19302"},
    {
      "urls": "turn:openrelay.metered.ca:80",
      "username": "openrelayproject",
      "credential": "openrelayproject",
    },
    {
      "urls": "turn:openrelay.metered.ca:443",
      "username": "openrelayproject",
      "credential": "openrelayproject",
    },
    {
      "urls": "turn:openrelay.metered.ca:443?transport=tcp",
      "username": "openrelayproject",
      "credential": "openrelayproject",
    },
  ];

  static Future<List<Map<String, dynamic>>> fetchIceServers() async {
    try {
      final response = await http
          .get(Uri.parse("$server/ice-servers"))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final list = data["data"];

        if (list is List && list.isNotEmpty) {
          return list
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error fetching ICE servers: $e');
    }

    return _fallbackIceServers;
  }
}
