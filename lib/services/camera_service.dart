import 'dart:convert';
import 'package:http/http.dart' as http;

class CameraService {

  static const String server =
      "https://camera-parent-server.onrender.com";

  // إلغاء اقتران جهاز - يقدر يستدعيها الجهاز المُقترَن نفسه في أي وقت
  // من إعداداته، بدون الحاجة لموافقة الوالد.
  static Future<bool> forgetDevice(String sessionId, String adminToken) async {
    try {
      final response = await http.delete(
        Uri.parse("$server/camera/sessions/$sessionId"),
        headers: {"X-Admin-Token": adminToken},
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> unpairDevice(String deviceToken) async {
    try {
      final response = await http.post(
        Uri.parse("$server/pairing/unpair"),
        headers: {"X-Device-Token": deviceToken},
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // بيجيب قائمة سيرفرات ICE (STUN/TURN) من السيرفر بدل ما تكون مكتوبة
  // ثابتة (hardcoded) في التطبيق. كده لو صاحب السيرفر ظبط TURN خاص بيه
  // (متغيرات TURN_URLS/TURN_USERNAME/TURN_CREDENTIAL على السيرفر)،
  // التطبيق هيستخدمه تلقائيًا من غير ما يحتاج تحديث/نشر جديد.
  //
  // fallback ثابت (STUN بس) لو الطلب فشل لأي سبب (مثلاً مفيش نت وقت
  // فتح الشاشة)، عشان التطبيق يقدر على الأقل يحاول الاتصال المباشر.
  static const List<Map<String, dynamic>> _fallbackIceServers = [
    {"urls": "stun:stun.l.google.com:19302"},
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
    } catch (_) {
      // هنستخدم القيمة الاحتياطية تحت
    }

    return _fallbackIceServers;
  }
}
