import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// خدمة FCM — تهيئة + جلب التوكن.
///
/// ملاحظة مهمة: في build-v2-0-0، معالجة Wake تتم على الجانب الأصلي
/// (WakeFcmService.kt). هذه الخدمة تُهيّئ FCM فقط وتجلب التوكن
/// ليرسله Child للسيرفر.
class FcmService {
  static Future<void> init() async {
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: false,
        sound: false,
      );
      debugPrint('[FCM] permission: ${settings.authorizationStatus}');

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.length > 20) {
        debugPrint('[FCM] token: ${token.substring(0, 20)}...');
      } else {
        debugPrint('[FCM] token: $token');
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        debugPrint('[FCM] token refreshed');
      });

      // على Android، الإشعارات تُعالج في WakeFcmService.kt
      // (Native side). لا نحتاج معالجة هنا.

      debugPrint('[FCM] init complete');
    } catch (e) {
      debugPrint('[FCM] init failed: $e');
    }
  }

  /// الحصول على التوكن الحالي (يُرسَل للسيرفر عند التسجيل)
  static Future<String?> getToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('[FCM] getToken failed: $e');
      return null;
    }
  }
}
