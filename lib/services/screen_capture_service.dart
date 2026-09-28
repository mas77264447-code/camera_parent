import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureService {
  /// يطلب التقاط الشاشة عبر flutter_webrtc مباشرة.
  /// أندرويد 10+ يعرض حوار الإذن تلقائياً.
  static Future<MediaStream> startScreenCapture() async {
    return await navigator.mediaDevices.getDisplayMedia({
      "video": {
        "width": 720,
        "height": 1280,
        "frameRate": 24,
      },
      "audio": false,
    });
  }
}