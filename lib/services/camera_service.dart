import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// خدمة الاتصال بالسيرفر: تجلب ICE servers، تتعامل مع pairing،
/// وتغلّف getUserMedia من WebRTC.
class CameraService {
  static const String server = "https://camera-parent-server.onrender.com";

  // ═══════════════════════════════════════════════════════════
  // ICE Servers
  // ═══════════════════════════════════════════════════════════

  /// true إذا كانت آخر قائمة رجعت من الـfallback (STUN فقط) لأن الجلب فشل.
  /// عندها لن يعمل الاتصال خلف NAT صارم/شبكات الجوال، فيجب إعادة الجلب.
  static bool lastIceFetchFailed = false;

  static Future<List<Map<String, dynamic>>> fetchIceServers() async {
    // السيرفر على استضافة مجانية ينام ويحتاج 30-60 ثانية ليستيقظ بعد إعادة التشغيل،
    // لذلك 3 محاولات بمهلة 25 ثانية (كانت محاولة واحدة بمهلة 10 فتفشل وتبقى STUN فقط).
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final res = await http
            .get(Uri.parse("$server/ice-servers"))
            .timeout(const Duration(seconds: 25));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final data = body["data"];
          if (data is List && data.isNotEmpty) {
            lastIceFetchFailed = false;
            return data.map((e) => Map<String, dynamic>.from(e)).toList();
          }
        }
        debugPrint("[CameraService] fetchIceServers bad response ${res.statusCode} (attempt $attempt)");
      } catch (e) {
        debugPrint("[CameraService] fetchIceServers failed (attempt $attempt): $e");
      }
      if (attempt < 3) await Future.delayed(Duration(seconds: 2 * attempt));
    }

    // fallback: STUN عام (قد لا يكفي للاتصال خلف NAT)
    lastIceFetchFailed = true;
    return [
      {"urls": "stun:stun.l.google.com:19302"},
    ];
  }

  // ═══════════════════════════════════════════════════════════
  // getUserMedia
  // ═══════════════════════════════════════════════════════════

  static Future<MediaStream> getUserMedia({
    bool audio = true,
    bool video = true,
    Map<String, dynamic>? videoConstraints,
  }) async {
    final constraints = <String, dynamic>{
      "audio": audio,
      "video": video ? (videoConstraints ?? true) : false,
    };
    return navigator.mediaDevices.getUserMedia(constraints);
  }

  // ═══════════════════════════════════════════════════════════
  // Pairing
  // ═══════════════════════════════════════════════════════════

  static Future<void> unpairDevice(String deviceToken) async {
    try {
      await http
          .post(
            Uri.parse("$server/pairing/unpair"),
            headers: {
              "Content-Type": "application/json",
              "X-Device-Token": deviceToken,
            },
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint("[CameraService] unpairDevice failed: $e");
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Parent auth
  // ═══════════════════════════════════════════════════════════

  static Future<String> parentRegister(
    String username,
    String password,
  ) async {
    final res = await http.post(
      Uri.parse("$server/parent/register"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"username": username, "password": password}),
    );
    if (res.statusCode != 200) {
      throw Exception("Register failed: ${res.statusCode} ${res.body}");
    }
    final body = jsonDecode(res.body);
    final data = (body["data"] ?? body) as Map;
    final token = data["admin_token"]?.toString() ?? "";
    if (token.isEmpty) {
      throw Exception("Register: no admin_token in response");
    }
    return token;
  }

  static Future<String> parentLogin(
    String username,
    String password,
  ) async {
    final res = await http.post(
      Uri.parse("$server/parent/login"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"username": username, "password": password}),
    );
    if (res.statusCode != 200) {
      throw Exception("Login failed: ${res.statusCode} ${res.body}");
    }
    final body = jsonDecode(res.body);
    final data = (body["data"] ?? body) as Map;
    final token = data["admin_token"]?.toString() ?? "";
    if (token.isEmpty) {
      throw Exception("Login: no admin_token in response");
    }
    return token;
  }

  // ═══════════════════════════════════════════════════════════
  // Forget device (delete session)
  // ═══════════════════════════════════════════════════════════

  static Future<void> forgetDevice(
    String sessionId,
    String adminToken,
  ) async {
    try {
      await http
          .delete(
            Uri.parse("$server/camera/sessions/$sessionId"),
            headers: {
              "X-Admin-Token": adminToken,
            },
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint("[CameraService] forgetDevice failed: $e");
    }
  }

  // ═══════════════════════════════════════════════════════════
  // (اختياري) createCameraSession — قديم، لكن نبقيه للتوافق
  // ═══════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> createCameraSession() async {
    final response = await http.post(Uri.parse("$server/camera/create"));
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      return {
        "sessionId": body["data"]["session_id"],
        "childUrl": body["data"]["child_url"],
      };
    }
    throw Exception("Server error: ${response.statusCode}");
  }
}
