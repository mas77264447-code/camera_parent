import sys

def replace_once(text, old, new, label):
    n = text.count(old)
    if n != 1:
        sys.exit(f"[FAIL] {label}: found {n} times (expected 1). No file written.")
    return text.replace(old, new)

path = sys.argv[1]
t = open(path, encoding="utf-8").read()

if "failReason" in t:
    sys.exit("[SKIP] already patched. No changes made.")

t = replace_once(
    t,
    "    WebSocket? ws;\n    String result = 'failed';\n    final completer = Completer<String>();",
    "    WebSocket? ws;\n    String result = 'failed';\n    String failReason = '';\n    final completer = Completer<String>();",
    "declare failReason")

t = replace_once(
    t,
    "            } else if (type == 'wake-failed' && !completer.isCompleted) {\n              completer.complete('failed');",
    "            } else if (type == 'wake-failed' && !completer.isCompleted) {\n"
    "              failReason = '${msg['reason'] ?? 'unknown'}'\n"
    "                  '${msg['detail'] != null ? ' / ${msg['detail']}' : ''}';\n"
    "              completer.complete('failed');",
    "capture reason from server")

t = replace_once(
    t,
    "        onError: (_) {\n          if (!completer.isCompleted) completer.complete('failed');\n        },\n        onDone: () {\n          if (!completer.isCompleted) completer.complete('failed');\n        },",
    "        onError: (_) {\n          if (failReason.isEmpty) failReason = 'ws_error';\n          if (!completer.isCompleted) completer.complete('failed');\n        },\n        onDone: () {\n          if (failReason.isEmpty) failReason = 'ws_closed';\n          if (!completer.isCompleted) completer.complete('failed');\n        },",
    "ws error/done reasons")

t = replace_once(
    t,
    "        onTimeout: () => 'failed',",
    "        onTimeout: () {\n          if (failReason.isEmpty) failReason = 'timeout';\n          return 'failed';\n        },",
    "timeout reason")

t = replace_once(
    t,
    "      debugPrint('[Wake] error: $e');\n      result = 'failed';",
    "      debugPrint('[Wake] error: $e');\n      failReason = 'connect_error: $e';\n      result = 'failed';",
    "catch reason")

t = replace_once(
    t,
    "          text =\n              '❌ الجهاز غير متصل بالسيرفر — يلزم فتح التطبيق على جهاز الطفل';\n          bg = Colors.red;",
    "          final String why;\n"
    "          if (failReason.startsWith('no_fcm_token')) {\n"
    "            why = 'لا يوجد رمز إشعارات محفوظ للطفل — افتح تطبيق الطفل مرة واحدة';\n"
    "          } else if (failReason.startsWith('fcm_error')) {\n"
    "            why = 'رفض Firebase الرسالة ($failReason)';\n"
    "          } else if (failReason.startsWith('not_found')) {\n"
    "            why = 'الجلسة غير موجودة على السيرفر';\n"
    "          } else if (failReason.startsWith('not_authorized')) {\n"
    "            why = 'غير مصرح — سجّل الدخول من جديد';\n"
    "          } else if (failReason.startsWith('fcm_disabled')) {\n"
    "            why = 'خدمة الإشعارات غير مفعلة على السيرفر';\n"
    "          } else {\n"
    "            why = 'لا رد من السيرفر ($failReason)';\n"
    "          }\n"
    "          text = '❌ فشل الإيقاظ: $why';\n"
    "          bg = Colors.red;",
    "snackbar text")

open(path, "w", encoding="utf-8").write(t)
print("OK: home_screen.dart updated in place")
