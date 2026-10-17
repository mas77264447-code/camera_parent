import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'stream_service.dart';

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
      if (token != null) {
        final shown = token.length > 20 ? token.substring(0, 20) : token;
        debugPrint('[FCM] token: $shown...');
      }

      // عند تدوير التوكن نعيد التسجيل مع السيرفر ليحفظ التوكن الجديد،
      // وإلا يبقى القديم عنده وتفشل الإيقاظة عبر FCM.
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        debugPrint('[FCM] token refreshed');
        StreamService.instance.refreshRegistration();
      });

      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _onOpened(initial);

      debugPrint('[FCM] init complete');
    } catch (e) {
      debugPrint('[FCM] init failed: $e');
    }
  }

  static void _onForeground(RemoteMessage msg) {
    debugPrint('[FCM] foreground: ${msg.data}');
    if (msg.data['action'] == 'wake_camera') {
      StreamService.instance.ensureCameraStarted();
      StreamService.instance.ensureHealthy();
    }
  }

  static void _onOpened(RemoteMessage msg) {
    debugPrint('[FCM] opened: ${msg.data}');
  }

  static Future<String?> getToken() async {
    try {
      // مهلة: التسجيل مع السيرفر ينتظر هذه الدالة، ولا نريد أن يتعطل الاتصال
      // عند الإقلاع إذا كانت خدمات Google بطيئة أو الشبكة غير جاهزة بعد.
      return await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[FCM] getToken failed: $e');
      return null;
    }
  }
}
