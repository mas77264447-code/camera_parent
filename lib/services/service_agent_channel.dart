import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stream_service.dart';

/// يستقبل أمر "start" من الجانب الأصلي (خدمة المقدمة بعد الإقلاع)
/// ويبدأ البث من البيانات المحفوظة، دون الحاجة إلى فتح الواجهة.
class ServiceAgentChannel {
  static const _channel = MethodChannel('camera_parent/service_agent');

  static void register() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'start':
          await _startFromPersistedState();
          return true;
        case 'stop':
          await StreamService.instance.stop();
          return true;
        default:
          throw MissingPluginException('Unknown method ${call.method}');
      }
    });
  }

  static Future<void> _startFromPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = prefs.getString('session_id');
    final deviceToken = prefs.getString('device_token');
    final deviceName = prefs.getString('device_name') ?? 'جهاز الطفل';
    final isPaired = prefs.getBool('is_paired') ?? false;
    if (!isPaired || sessionId == null || deviceToken == null) {
      debugPrint('[ServiceAgent] no persisted session, skipping start');
      return;
    }
    await StreamService.instance.start(
      sessionId: sessionId,
      deviceToken: deviceToken,
      cameraName: deviceName,
    );
  }
}
