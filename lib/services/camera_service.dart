import 'dart:convert';
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

      return {
        "child_url": data["data"]["child_url"],
        "session_id": data["data"]["session_id"],
        "dashboard_url": data["data"]["dashboard_url"],
      };
    }

    return null;
  }

  static Future<List<Map<String, dynamic>>> fetchSessions() async {
    final response = await http.get(Uri.parse("$server/camera/sessions"));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return List<Map<String, dynamic>>.from(data["data"]);
    }

    return [];
  }
}
