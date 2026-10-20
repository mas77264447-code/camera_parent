import 'package:flutter/services.dart';

/// يكتب أخطاء Dart غير المُلتقطة عبر Kotlin (BootLog / MediaStore) —
/// أداة تشخيص مؤقتة. الكتابة المباشرة إلى Download كانت تفشل بصمت.
class CrashLogger {
  static const _channel = MethodChannel('camera_parent/diag_log');

  static Future<void> log(String source, Object error, StackTrace? stack) async {
    try {
      final text = StringBuffer()
        ..writeln('DART-ERROR [$source] ${DateTime.now()}')
        ..writeln(error.toString());
      if (stack != null) text.writeln(stack.toString());
      await _channel.invokeMethod('log', text.toString());
    } catch (_) {
      // نتجاهل: لا نريد أن يفشل التسجيل بسبب خطأ آخر
    }
  }
}
