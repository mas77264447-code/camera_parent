import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stream_service.dart';

class ServiceAgentChannel {
  static const _channel = MethodChannel('camera_parent/service_agent');

  static void register() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'start':
          final started = await _startFromPersistedState();
          if (!started) {
            throw PlatformException(
              code: 'NO_SESSION',
              message: 'No paired session — waiting for user to pair',
            );
          }
          return true;
        case 'stop':
          await StreamService.instance.stop();
          return true;
        default:
          throw MissingPluginException('Unknown method ${call.method}');
      }
    });
  }

  static Future<bool> _startFromPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = prefs.getString('session_id');
    final deviceToken = prefs.getString('device_token');
    final deviceName = prefs.getString('device_name') ?? 'جهاز الطفل';
    final isPaired = prefs.getBool('is_paired') ?? false;

    if (!isPaired || sessionId == null || deviceToken == null) {
      debugPrint('[ServiceAgent] no persisted session — returning false');
      return false;
    }

    await StreamService.instance.start(
      sessionId: sessionId,
      deviceToken: deviceToken,
      cameraName: deviceName,
    );
    return true;
  }
}
