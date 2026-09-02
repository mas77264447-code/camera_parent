import 'package:flutter/services.dart';

class ScreenCaptureService {
  static const _channel = MethodChannel("camera_parent/screen_capture");

  static Future<bool> request() async {
    final result = await _channel.invokeMethod("requestScreenCapture");
    return result == "granted";
  }
}
