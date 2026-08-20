import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CameraService {

  static const String server =
      "https://camera-parent-server.onrender.com";

  static Future<Map<String, String>?> createCameraSession(String name) async {

    final response = await http.post(
      Uri.parse("$server/camera/create"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"name": name}),
    );

    if (response.statusCode == 200) {

      final data = jsonDecode(response.body);

      final childUrl = data["data"]["child_url"];
      final sessionId = data["data"]["session_id"];
      final dashboardUrl = data["data"]["dashboard_url"];

      return {
        "child_url": childUrl,
        "session_id": sessionId,
        "dashboard_url": dashboardUrl,
      };
    }

    return null;
  }

  static Future<void> uploadFrame(String sessionId, Uint8List jpegBytes) async {
    await http.post(
      Uri.parse("$server/camera/frame?session=$sessionId"),
      headers: {"Content-Type": "image/jpeg"},
      body: jpegBytes,
    );
  }
}
