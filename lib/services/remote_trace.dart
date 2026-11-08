import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_service.dart';

/// تتبّع تشخيصي فقط: يرسل أسطرًا قصيرة إلى السيرفر لتظهر في سجل Render.
/// كل شيء داخل try/catch ولا يغيّر أي سلوك في التطبيق.
class RemoteTrace {
  static const MethodChannel _channel = MethodChannel('camera_parent/diag');
  static bool _exitInfoSent = false;

  static void log(String line) {
    unawaited(send(<String>[line]));
  }

  static Future<void> send(List<String> lines) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('device_token');
      if (token == null || token.isEmpty) return;
      await http
          .post(
            Uri.parse('${CameraService.server}/debug/trace'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'X-Device-Token': token,
            },
            body: jsonEncode(<String, dynamic>{'lines': lines}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// يرسل أسباب موت العملية السابقة (ApplicationExitInfo) مرة لكل تشغيل.
  static Future<void> reportLastExit() async {
    if (_exitInfoSent) return;
    _exitInfoSent = true;
    try {
      final r = await _channel.invokeMethod<List<dynamic>>('exitInfo');
      final lines = (r ?? const <dynamic>[]).map((e) => e.toString()).toList();
      if (lines.isEmpty) return;
      await send(<String>['--- process start; previous exits ---', ...lines]);
    } catch (_) {}
  }
}
