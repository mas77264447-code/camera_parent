import re

# 1. إضافة صلاحيات الواي فاي
manifest_path = 'android/app/src/main/AndroidManifest.xml'
with open(manifest_path, 'r') as f:
    manifest = f.read()

if "ACCESS_WIFI_STATE" not in manifest:
    manifest = manifest.replace(
        '<uses-permission android:name="android.permission.WAKE_LOCK"/>',
        '<uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>\n    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>'
    )
    with open(manifest_path, 'w') as f:
        f.write(manifest)
    print("✅ تمت إضافة صلاحيات الواي فاي.")

# 2. إصلاح خطأ الـ await في الدارت
dart_path = 'lib/services/stream_service.dart'
with open(dart_path, 'r') as f:
    dart = f.read()

if "void _handleMessage(dynamic message) {" in dart:
    dart = dart.replace(
        "void _handleMessage(dynamic message) {",
        "Future<void> _handleMessage(dynamic message) async {"
    )
    # تعديل الـ listen عشان يقبل الـ Future
    dart = re.sub(r'_ws!\.listen\(\s*_handleMessage,', '_ws!.listen(\n        (dynamic msg) => _handleMessage(msg),', dart)
    with open(dart_path, 'w') as f:
        f.write(dart)
    print("✅ تم إصلاح دالة _handleMessage (إضافة async).")

# 3. حذف سكريبتات البايثون عشان متترفعش على جيت هاب
import os
for script in ['fix_bg.py', 'fix_connection.py']:
    if os.path.exists(script):
        os.remove(script)
        print(f"🧹 تم حذف ملف {script} المؤقت.")
