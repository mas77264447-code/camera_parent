import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenCaptureService {
  static Future<MediaStream> startScreenCapture() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': false,
      'video': true,
    };
    return await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
  }
}
