#!/data/data/com.termux/files/usr/bin/bash
# شغّله خارج مجلد الريبو (مثلاً ~). لا ترفع الملف الناتج لـ git أبداً.
set -e
command -v keytool >/dev/null || pkg install -y openjdk-17
keytool -genkeypair -v -keystore ~/release.jks -alias release \
  -keyalg RSA -keysize 2048 -validity 10000
echo
echo "=== انسخ هذا النص كاملاً إلى GitHub Secret باسم KEYSTORE_BASE64 ==="
base64 -w0 ~/release.jks
echo
echo "=== واحتفظ بنسخة من ~/release.jks وكلمات المرور خارج الريبو ==="
