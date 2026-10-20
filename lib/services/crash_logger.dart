import 'dart:io';

/// يكتب أخطاء Dart غير المُلتقطة إلى نفس ملف اللوق الذي يكتب فيه الطرف
/// الأصلي (Kotlin) — أداة تشخيص مؤقتة لمعرفة سبب انقطاع اتصال الابن
/// المفاجئ (ws close code=1006) عند قبول مشاهد جديد.
class CrashLogger {
  static const _path = '/storage/emulated/0/Download/camera_parent_crash.log';

  static Future<void> log(String source, Object error, StackTrace? stack) async {
    try {
      final file = File(_path);
      final buf = StringBuffer()
        ..writeln()
        ..writeln('=== ${DateTime.now()} [dart/$source] ===')
        ..writeln(error.toString());
      if (stack != null) buf.writeln(stack.toString());
      await file.writeAsString(buf.toString(), mode: FileMode.append, flush: true);
    } catch (_) {
      // تجاهل: لا نريد أن يفشل تسجيل الخطأ بسبب خطأ آخر
    }
  }
}
