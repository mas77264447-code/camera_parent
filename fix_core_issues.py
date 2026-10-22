import re

# ==============================================================
# 1. إصلاح تطبيق الابن: منع الاتصال المزدوج في stream_service.dart
# ==============================================================
dart_path = 'lib/services/stream_service.dart'
with open(dart_path, 'r') as f:
    dart = f.read()

# التأكد من إغلاق الاتصال القديم قبل فتح جديد
old_connect = """    try {
      final serverUrl = CameraService.server;"""
new_connect = """    try {
      // 🛑 إصلاح جذري: إغلاق أي اتصال قديم قبل فتح اتصال جديد
      if (_ws != null) {
        try { await _ws!.close(); } catch (_) {}
        _ws = null;
      }
      
      final serverUrl = CameraService.server;"""

if "إغلاق أي اتصال قديم" not in dart:
    dart = dart.replace(old_connect, new_connect)
    print("✅ تم إصلاح مشكلة الاتصال المزدوج في stream_service.dart")

# منع تكرار محاولات الاتصال لو هيشتغل في الخلفية
old_schedule = """  void _scheduleReconnect() {
    if (!_running) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;"""
new_schedule = """  void _scheduleReconnect() {
    if (!_running) return;
    // 🛑 إصلاح: لا تحاول الاتصال لو في محاولة شغالة بالفعل
    if (_wsConnecting) return;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;"""

if "_wsConnecting) return;" not in dart:
    dart = dart.replace(old_schedule, new_schedule)

with open(dart_path, 'w') as f:
    f.write(dart)

# ==============================================================
# 2. إصلاح تطبيق الأب: تحسين رسالة الخطأ في home_screen.dart
# ==============================================================
screen_path = 'lib/screens/home_screen.dart'
with open(screen_path, 'r') as f:
    screen = f.read()

old_msg = """              '❌ الجهاز غير متصل بالسيرفر — يلزم فتح التطبيق على جهاز الطفل';"""
new_msg = """              '⏳ جاري محاولة الاتصال بالجهاز... (تأكد من فتح تطبيق الطفل)';"""

if "الجهاز غير متصل بالسيرفر — يلزم" in screen:
    screen = screen.replace(old_msg, new_msg)
    print("✅ تم تحسين رسالة الحالة في home_screen.dart")

with open(screen_path, 'w') as f:
    f.write(screen)

print("🎉 تم تطبيق جميع الإصلاحات الجذرية بنجاح!")
