import 'dart:convert';
import 'package:http/http.dart' as http;

class CameraService {

  // عدل هذا العنوان لاحقاً إلى IP السيرفر الخاص بك
  static const String server =
      "http://192.168.1.96:8080";

  static Future<String> createCameraSession() async {

    final response = await http.post(
      Uri.parse("$server/camera/create"),
    );

    if (response.statusCode == 200) {

      final data = jsonDecode(response.body);

      final sessionId =
          data["data"]["session_id"];

      return
          "$server/camera/join/$sessionId";
    }

    throw Exception(
      "Server error: ${response.statusCode}"
    );
  }
}
