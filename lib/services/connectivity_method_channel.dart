
import 'package:flutter/services.dart';

class ConnectivityMethodChannel {
  static const MethodChannel _channel =
      MethodChannel('camera_parent/connectivity');

  static void initialize({
    required Future<void> Function(bool online) onNetworkChanged,
  }) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'networkChanged') {
        final online = call.arguments == true;
        await onNetworkChanged(online);
      }
    });
  }
}
