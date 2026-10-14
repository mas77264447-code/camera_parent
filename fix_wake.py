import sys, re

def replace_once(text, old, new, label):
    n = text.count(old)
    if n != 1:
        sys.exit(f"[FAIL] {label}: found {n} times (expected 1). No file written.")
    return text.replace(old, new)

def cut_between(text, start_marker, end_marker, new, label):
    s = text.find(start_marker)
    if s < 0 or text.count(start_marker) != 1:
        sys.exit(f"[FAIL] {label}: start marker not unique/missing. No file written.")
    e = text.find(end_marker, s)
    if e < 0:
        sys.exit(f"[FAIL] {label}: end marker missing. No file written.")
    return text[:s] + new + text[e:]

kt_path, dart_path = sys.argv[1], sys.argv[2]

# ---------- MainActivity.kt (child) ----------
kt = open(kt_path, encoding="utf-8").read()
kt = cut_between(
    kt,
    '                // ✅ إحضار التطبيق للمقدمة',
    '                // ✅ فحص صلاحية Overlay',
    '                // ✅ إحضار التطبيق للمقدمة متوقف عمداً: لا فتح للواجهة ولا إشعار.\n'
    '                // البث يعمل من StreamForegroundService في الخلفية.\n'
    '                "bringToForeground" -> result.success(false)\n\n',
    "kotlin bringToForeground case")
kt = cut_between(
    kt,
    '    // ═══════════════════════════════════════════════\n    // Full-Screen Intent Notification',
    '    override fun onActivityResult(',
    '',
    "kotlin notification function")

# ---------- stream_service.dart ----------
dt = open(dart_path, encoding="utf-8").read()

dt = cut_between(
    dt,
    '  /// يطلب من الجانب الأصلي إحضار التطبيق للمقدمة.',
    '  Future<void> _sendOfferTo(String viewerId, String callerName) async {',
    '  /// معطّل عمداً: لا يُحضر التطبيق ولا يعرض إشعاراً. البث يعمل من الخدمة في الخلفية.\n'
    '  Future<bool> _bringToForeground({int maxAttempts = 3}) async {\n'
    '    return true;\n'
    '  }\n\n',
    "dart _bringToForeground method")

dt = replace_once(
    dt,
    '''    if (!_broadcastScreen && !isForeground) {
      _pendingCameraStart = true;
      _updateStatus("جاري إظهار التطبيق لفتح الكاميرا...");

      final ok = await _bringToForeground();
      if (!ok) {
        _updateStatus("مطلوب فتح التطبيق على الجهاز لتشغيل الكاميرا");
        // ✅ لا تُلغِ _pendingCameraStart — اتركها true حتى تُفتح
        // الكاميرا تلقائياً عند عودة المستخدم للتطبيق.
      }
      return;
    }
''',
    '''    // لا نُحضر التطبيق في الخلفية: نكمل التشغيل من الخدمة مباشرة.
''',
    "dart background early-return block")

# Remove the lifecycleBefore block in _handleApprovedViewer
dt = cut_between(
    dt,
    '        final lifecycleBefore = WidgetsBinding.instance.lifecycleState;',
    '        await _startMediaSource();\n      }\n    }',
    '',
    "dart lifecycleBefore block")

open(kt_path, "w", encoding="utf-8").write(kt)
open(dart_path, "w", encoding="utf-8").write(dt)
print("OK: both files updated in place")
