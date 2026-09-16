import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Screen capture is owned by flutter_webrtc.
/// Android's MediaProjection consent and projection lifecycle must stay in the
/// same capture session; do not request a second native projection token.
class ScreenCaptureService {
  static Future<MediaStream> startScreenCapture() async {
    return navigator.mediaDevices.getDisplayMedia({
      'video': true,
      'audio': true,
    });
  }
}
