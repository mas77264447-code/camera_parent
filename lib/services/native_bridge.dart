
import 'package:flutter/services.dart';
import 'agent_service.dart';

class NativeBridge {
  static const MethodChannel _channel =
      MethodChannel('camera_parent/service');

  static Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'startAgent':
          AgentService.instance.start();
          break;
        case 'stopAgent':
          AgentService.instance.stop();
          break;
      }
    });
  }
}
