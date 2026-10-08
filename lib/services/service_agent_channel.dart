import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stream_service.dart';

class ServiceAgentChannel {
  static const _channel = MethodChannel('camera_parent/service_agent');
  static const _bootChannel = MethodChannel('camera_parent/boot_warmup');

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
      await _signalCameraReady();
      return;
    }

    await StreamService.instance.start(
      sessionId: sessionId,
      deviceToken: deviceToken,
      cameraName: deviceName,
    );

    try {
      await StreamService.instance.ensureCameraStarted();
      debugPrint('[ServiceAgent] camera started OK');
    } catch (e) {
      debugPrint('[ServiceAgent] camera start failed: $e');
    }

    // ✅ أبلغ Native أن الكاميرا جاهزة — دع الـ Activity ترجع للخلفية
    await _signalCameraReady();
  }

  static Future<void> _signalCameraReady() async {
    try {
      await _bootChannel.invokeMethod('cameraReady');
      debugPrint('[ServiceAgent] signaled cameraReady to native');
    } catch (e) {
      debugPrint('[ServiceAgent] signal failed: $e');
    }
  }
}
