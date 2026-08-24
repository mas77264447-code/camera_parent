import 'dart:convert';
import 'package:http/http.dart' as http;

class CameraService {

  static const String server =
      "http://192.168.1.96:8080";


  static Future<Map<String, dynamic>> createCameraSession() async {

    final response = await http.post(
      Uri.parse("$server/camera/create"),
    );


    if (response.statusCode == 200) {

      final body = jsonDecode(response.body);

      return {
        "sessionId": body["data"]["session_id"],
        "childUrl": body["data"]["child_url"],
      };

    }


    throw Exception(
      "Server error: ${response.statusCode}",
    );
  }
}
