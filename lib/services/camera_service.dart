import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CameraService {

  static const String server =
      "https://camera-parent-server.onrender.com";

  static Future<Map<String, String>?> createCameraSession() async {

    final response = await http.post(
      Uri.parse("$server/camera/create"),
    );

    if (response.statusCode == 200) {

      final data = jsonDecode(response.body);

      final childUrl = data["data"]["child_url"];
      final sessionId = data["data"]["session_id"];

      return {
        "child_url": childUrl,
        "session_id": sessionId,
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
