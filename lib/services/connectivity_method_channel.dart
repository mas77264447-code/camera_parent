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

    // الحدث الأول من Kotlin قد يصل قبل تسجيل المعالج هنا فيضيع؛
    // لذلك نسأل عن الحالة الحالية صراحةً.
    _channel.invokeMethod<bool>('getState').then((online) async {
      if (online != null) await onNetworkChanged(online);
    }).catchError((_) {});
  }
}
