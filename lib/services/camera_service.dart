import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class CameraService {
  static const String server =
      "https://camera-parent-server.onrender.com";

  static const Duration httpTimeout =
      Duration(seconds: 10);


  static Future<bool> forgetDevice(
      String sessionId,
      String adminToken) async {
    try {
      final response = await http.delete(
        Uri.parse("$server/camera/sessions/$sessionId"),
        headers: {
          "X-Admin-Token": adminToken,
        },
      ).timeout(httpTimeout);

      return response.statusCode == 200;

    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error: $e');
      }
      return false;
    }
  }


  static Future<bool> verifyAdminToken(
      String adminToken) async {
    try {
      final response = await http.post(
        Uri.parse("$server/admin/verify"),
        headers: {
          "Content-Type": "application/json"
        },
        body: jsonEncode({
          "admin_token": adminToken
        }),
      ).timeout(httpTimeout);

      return response.statusCode == 200;

    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error: $e');
      }
      return false;
    }
  }


  static Future<bool> unpairDevice(
      String deviceToken) async {
    try {
      final response = await http.post(
        Uri.parse("$server/pairing/unpair"),
        headers: {
          "X-Device-Token": deviceToken,
        },
      ).timeout(httpTimeout);

      return response.statusCode == 200;

    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error: $e');
      }
      return false;
    }
  }


  // إضافة WebRTC camera stream
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



  static const List<Map<String, dynamic>>
      _fallbackIceServers = [

    {
      "urls": "stun:stun.l.google.com:19302"
    },

  ];



  static Future<List<Map<String, dynamic>>>
      fetchIceServers() async {

    try {

      final response = await http
          .get(Uri.parse("$server/ice-servers"))
          .timeout(
            const Duration(seconds: 6),
          );


      if (response.statusCode == 200) {

        final data = jsonDecode(response.body);

        final list = data["data"];


        if (list is List && list.isNotEmpty) {

          return list
              .map(
                (e) => Map<String, dynamic>.from(e as Map),
              )
              .toList();

        }

      }

    } catch (e) {

      if (kDebugMode) {
        debugPrint(
          'Error fetching ICE servers: $e',
        );
      }

    }


    return _fallbackIceServers;

  }

}