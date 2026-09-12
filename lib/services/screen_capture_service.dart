import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureService {
  static const MethodChannel _channel =
      MethodChannel("camera_parent/screen_capture");


  static Future<bool> request() async {
    final result = await _channel.invokeMethod(
      "requestScreenCapture",
    );

    return result == "granted";
  }


  static Future<MediaStream> startScreenCapture() async {

    final granted = await request();

    if (!granted) {
      throw Exception(
        "Screen capture permission denied",
      );
    }


    return await navigator.mediaDevices.getDisplayMedia({

      "video": true,

      "audio": true,

    });

  }
}