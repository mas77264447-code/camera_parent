import 'dart:convert';
import 'package:http/http.dart' as http;

class CameraService {

  static const String server =
      "http://192.168.1.96:8080";

  static Future<String?> createCameraSession() async {

    final response = await http.post(
      Uri.parse("$server/camera/create"),
    );

    if (response.statusCode == 200) {

      final data = jsonDecode(response.body);

      final childUrl =
          data["data"]["child_url"];

      return childUrl;
    }

    return null;
  }
}
