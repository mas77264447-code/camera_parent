
dev_dependencies:
  flutter_test:
    sdk: flutter

  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
EOF

cat > pubspec.yaml << 'EOF'
name: camera_parent
description: "Camera Parent App"
publish_to: 'none'

version: 1.0.0+1

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

  cupertino_icons: ^1.0.8
  http: ^1.2.2
  flutter_webrtc: ^1.5.2
  permission_handler: ^11.3.1

dev_dependencies:
  flutter_test:
    sdk: flutter

  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
EOF

cat pubspec.yaml
cat > pubspec.yaml << 'EOF'
name: camera_parent
description: "Camera Parent App"
publish_to: 'none'

version: 1.0.0+1

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

  cupertino_icons: ^1.0.8
  http: ^1.2.2
  flutter_webrtc: ^1.5.2
  permission_handler: ^11.3.1

dev_dependencies:
  flutter_test:
    sdk: flutter

  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
EOF

cat pubspec.yaml
git add .
git commit -m "Upgrade flutter_webrtc to 1.5.2 for compatibility"
git push
unzip -o ~/storage/downloads/camera_parent-audiofix.zip -d ~/camera_parent
wc -l server/index.js
ls -la ~/storage/downloads/camera_parent-audiofix.zip
unzip -p ~/storage/downloads/camera_parent-audiofix.zip server/index.js | wc -l
ls -la ~/storage/downloads/camera_parent-audiofix.zip
unzip -o ~/storage/downloads/camera_parent-audiofix.zip -d ~/camera_parent
wc -l server/index.js
git add .
git commit -m "Fix autoplay black screen - mute video then show unmute button"
git push
unzip -o ~/storage/downloads/camera_parent-2way.zip -d ~/camera_parent
wc -l server/index.js lib/screens/camera_stream_screen.dart lib/screens/camera_viewer_screen.dart
git add .
git commit -m "Add two-way video/audio - broadcaster also sees viewer"
git push
unzip -o ~/storage/downloads/camera_parent-wakelock.zip -d ~/camera_parent
wc -l pubspec.yaml lib/screens/camera_stream_screen.dart
grep wakelock pubspec.yaml
rm -f pubspec.yaml lib/screens/camera_stream_screen.dart
unzip -o ~/storage/downloads/camera_parent-wakelock.zip -d ~/camera_parent
wc -l pubspec.yaml lib/screens/camera_stream_screen.dart
ls -la ~/storage/downloads/camera_parent-wakelock.zip
unzip -o ~/storage/downloads/camera_parent-wakelock.zip -d ~/camera_parent
wc -l pubspec.yaml lib/screens/camera_stream_screen.dart
git add .
git commit -m "Add wakelock to prevent screen auto-lock while streaming"
git push
static Future<String> createCameraSession() async {
cd ~/camera-parent-webrtc-viewer
nano lib/services/camera_service.dart
git add .
git commit -m "Fix camera session"
git push
camera-parent-webrtc-viewer
lib
screens
cd ~/camera-parent-webrtc-viewer/lib/screens
ls -la
cp home_screen.dart ~/storage/downloads/
home_screen.dart
cd ~/camera-parent-webrtc-viewer/lib/services
ls -la
cd ~/camera-parent-webrtc-viewer
nano lib/screens/home_screen.dart
git add lib/screens/home_screen.dart
git commit -m "Fix camera session return type"
git push
nano pubspec.yaml
flutter clean
flutter pub get
git status
git add pubspec.yaml
git commit -m "Update flutter webrtc version"
git push
git add pubspec.yaml
git commit -m "Update flutter webrtc version"
git push
android/app/build.gradle
cd ~/camera-parent-webrtc-viewer
ls -la android
find android -name "build.gradle"
cat android/app/build.gradle.kts
nano android/app/build.gradle.kts
git add android/app/build.gradle.kts
git commit -m "Update Android compile SDK 36"
git push
Note that updating a library or application's compileSdk (which
           allows newer APIs to be used) can be done separately from updating
           targetSdk (which opts the app in to new runtime behavior) and
           minSdk (which determines which devices the app can be installed
           on).

      19.  Dependency 'androidx.window.extensions.core:core:1.0.0' requires libraries and applications that
           depend on it to compile against version 33 or later of the
           Android APIs.

           :flutter_webrtc is currently compiled against android-31.

           Recommended action: Update this project to use a newer compileSdk
           of at least 33, for example 36.

           Note that updating a library or application's compileSdk (which
cd ~/camera-parent-webrtc-viewer
ls -la
cd ~/camera-parent-webrtc-viewer
rm -f Get Process Run
git status
git add -u
git commit -m "Remove accidental files"
git push
cat pubspec.yaml
cat android/app/build.gradle.kts
rm pubspec.lock
git add pubspec.yaml
git rm pubspec.lock
git commit -m "Refresh dependencies for flutter webrtc"
git push
cd ~/camera-parent-webrtc-viewer
cat android/build.gradle.kts
ه
cat android/gradle.properties
cat android/settings.gradle.kts
nano android/settings.gradle.kts
git add android/settings.gradle.kts
git commit -m "Fix Android Gradle plugin versions"
git push
cd ~/clone/android
nano settings.gradle
cd /Users/builder/clone/android
nano ~/camera_parent/android/settings.gradle.kts
cd ~/camera_parent
flutter clean
flutter build apk --release
pkg update && pkg upgrade -y
curl -s https://raw.githubusercontent.com/Hax4us/flutter_in_termux/master/install.sh | bash
cd ~/camera_parent
flutter build apk --release --target-platform android-arm64
cd ~/camera_parent
mkdir -p .github/workflows
nano .github/workflows/build.yml
git add .github/workflows/build.yml
git commit -m "Add GitHub Actions build workflow"
git push
pkg install git -y
git config --global user.name "hilmy"
git config --global user.email "mas77264447@gmail.com"
cd ~/camera_parent
git status
git add -A
git commit -m "Fix AGP version, remove stray file, add CI workflow"
git push
cp /sdcard/Download/camera_parent-fixed.zip ~/camera_parent-fixed.zip
cp /sdcard/Download/camera_parent-final.zip ~/camera_parent-final.zip
ls /sdcard/Download/ | grep -i camera
cp "/sdcard/Download/camera_parent-final.zip" ~/camera_parent-final.zip
cd ~/camera_parent
unzip -o ~/camera_parent-final.zip -d ~/camera_parent
git status
git diff server/index.js
git status -s
rm "tatus -s"
git status -s
cd ~/camera_parent
mkdir -p .github/workflows
cat > .github/workflows/build.yml << 'EOF'
name: Build APK

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '17'

      - uses: subosito/flutter-action@v2
        with:
          channel: 'stable'

      - run: flutter pub get
      - run: flutter build apk --release

      - uses: actions/upload-artifact@v4
        with:
          name: release-apk
          path: build/app/outputs/flutter-apk/app-release.apk
EOF

git status -s
ls -la .github/workflows/
cat .gitignore | grep -i github
git add -f .github/workflows/build.yml
git status -s
git ls-files | grep workflow
git log --oneline -- .github/workflows/build.yml
git add -A
git commit -m "Fix AGP version, remove stray file, add CI workflow"
git push
unzip -o ~/storage/downloads/camera_parent-nosplit.zip -d ~/camera_parent
/ls -la ~/storage/downloads/camera_parent-nosplit.zip
ls -la ~/storage/downloads/camera_parent-nosplit.zip
cd ~/camera_parent
unzip -o ~/storage/downloads/camera_parent-nosplit.zip -d ~/camera_parent
wc -l server/index.js lib/screens/camera_stream_screen.dart
git add .
git commit -m "Remove split-screen, revert to fullscreen view for the other party"
git push
git add .
git commit -m "Remove split-screen, revert to fullscreen view for the other party"
git push
mkdir -p android/gradle/wrapper
unzip -o ~/storage/downloads/camera_parent-gradlefix.zip -d ~/camera_parent
cat android/gradle/wrapper/gradle-wrapper.properties
ls -la ~/storage/downloads/camera_parent-gradlefix.zip
rm -f android/gradle/wrapper/gradle-wrapper.properties
unzip -o ~/storage/downloads/camera_parent-gradlefix.zip -d ~/camera_parent
cat android/gradle/wrapper/gradle-wrapper.properties
git add .
git commit -m "Fix Gradle version for Codemagic build compatibility"
git push
unzip -o ~/storage/downloads/camera_parent-quality-autostart.zip -d ~/camera_parent
wc -l server/index.js lib/screens/camera_stream_screen.dart
unzip -o ~/storage/downloads/camera_parent-quality-autostart.zip -d ~/camera_parent
wc -l server/index.js lib/screens/camera_stream_screen.dart
git add .
git commit -m "Auto-connect on link open, improve video quality, persistent mute toggle"
git push
unzip -o ~/storage/downloads/camera_parent-webrtc-order-fix.zip -d ~/camera_parent
wc -l server/index.js
cd ~/camera_parent
wc -l server/index.js
unzip -o ~/storage/downloads/camera_parent-webrtc-order-fix.zip -d ~/camera_parent
wc -l server/index.js
git add .
git commit -m "Fix WebRTC negotiation order - setRemoteDescription before addTrack"
git push
git add .
git commit -m "Fix WebRTC negotiation order - setRemoteDescription before addTrack"
git push
unzip -o ~/storage/downloads/camera_parent-oneway.zip -d ~/camera_parent
wc -l server/index.js
git add .
git commit -m "Make call one-way: viewer sends to app only, no video shown to viewer"
git push
unzip -o ~/storage/downloads/camera_parent-debug-ids.zip -d ~/camera_parent
wc -l lib/screens/camera_stream_screen.dart
git add .
git commit -m "Add stream ID diagnostics to debug remote/local video mixup"
git push
unzip -o ~/storage/downloads/camera_parent-deep-debug.zip -d ~/camera_parent
wc -l lib/screens/camera_stream_screen.dart
cd ~/camera_parent
unzip -o ~/storage/downloads/camera_parent-deep-debug.zip -d ~/camera_parent
wc -l lib/screens/camera_stream_screen.dart
git add .
git commit -m "Add detailed answer/ICE diagnostics"
git push
cd ~/camera_parent
unzip -o ~/storage/downloads/camera_parent-metered-turn.zip -d ~/camera_parent
wc -l server/index.js lib/services/camera_service.dart lib/screens/camera_stream_screen.dart lib/screens/camera_viewer_screen.dart
git add .
git commit -m "Use dedicated Metered.ca TURN credentials for more reliable connections"
git push
cd ~/camera_parent.
cd ~/camera_parent
unzip -o ~/storage/downloads/camera_parent-keepalive.zip -d ~/camera_parent
wc -l server/index.js lib/screens/camera_stream_screen.dart
git add .
git commit -m "Add WebSocket keepalive ping and auto-reconnect"
git push
unzip -o ~/storage/downloads/camera_parent-lifecycle-fix.zip -d ~/camera_parent
wc -l lib/screens/camera_stream_screen.dart
git add .
git commit -m "Handle app resume: recover camera and reconnect if needed"
git push
/camera_parent $ ~/camera_parent $
~/camera_parent $ /camera_parent $ ~/camera_parent $ familyguard-main.zip
familyguard-main.zip: command not found
~/camera_parent $
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
familyguard-main.zip:: command not found
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
~/camera_parent $
bash: /camera_parent: No such file or directory
familyguard-main.zip:: command not found
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
No command bash: found, did you mean:
familyguard-main.zip::: command not found
No command bash: found, did you mean:
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
~/camera_parent $
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
familyguard-main.zip:: command not found
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
No command bash: found, did you mean:
familyguard-main.zip::: command not found
No command bash: found, did you mean:
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
No command bash: found, did you mean:
familyguard-main.zip::: command not found
No command bash: found, did you mean:
No command No found, did you mean:
No command Command found, did you mean:
familyguard-main.zip:::: command not found
No command No found, did you mean:
No command Command found, did you mean:
No command bash: found, did you mean:
bash: /data/data/com.termux/files/home/camera_parent: Is a directory
~/camera_parent $ cd familyguard-main && ls
bash: cd: familyguard-main: No such file or directory
~/camera_parent $
unzip familyguard-main.zip
cd familyguard-main
ls
unzip camera_parent-final.zip && cd familyguard-main && ls
cd ~/Downloads
ls familyguard
cd ~/familyguard
pkg update && pkg upgrade
pkg install python git nodejs
termux-setup-storage
python --version
node --version
pkg update
pkg install python
pip install flask
pkg update
pkg install python
ip addr
pkg install iproute2
ip addr
ifconfig
mkdir server
cd server
nano app.py
python app.py
pkg install ffmpeg
pkg install openssh
cloudflared tunnel --url http://localhost:8080
cd ~/camera_parent
nano lib/services/camera_service.dart
cd ~/camera_parent/server
npm start
cd ~/camera_parent
grep -R "camera-parent-server.onrender.com" .
nano lib/services/camera_service.dart
cd ~/camera_parent/server
npm start
ps -A | grep node
pkg install cloudflared
cloudflared tunnel --url http://localhost:8080
cd server
python app.py
camera-parent-server.onrender.com
cd ~/camera_parent
camera-parent-server.onrender.com
ls
cd ~/camera_parent/server
ls
cd ~/camera_parent/server
ls
cat package.json
head -50 index.js
~/camera_parent/server
npm install
npm start
cd ~/camera_parent/server
npm start
ngrok http 8080
~/start_camera_parent.sh
cd ~/camera_parent
nano lib/services/camera_service.dart
cat lib/services/camera_service.dart
grep -c "class CameraService" lib/services/camera_service.dart
wc -l lib/services/camera_service.dart
git add -A
git commit -m "Update server URL to Cloudflare Tunnel"
git push
cd ~/camera_parent
git checkout lib/services/camera_service.dart
cat lib/services/camera_service.dart
rm lib/services/camera_service.dart
pwd
ls lib/services/
mkdir -p lib/services
cat lib/services/camera_service.dart
base64 -d > lib/services/camera_service.dart << 'B64EOF'
aW1wb3J0ICdkYXJ0OmNvbnZlcnQnOwppbXBvcnQgJ2RhcnQ6bWF0aCc7CmltcG9ydCAncGFja2FnZTpodHRwL2h0dHAuZGFydCcgYXMgaHR0cDsKaW1wb3J0ICdwYWNrYWdlOnNoYXJlZF9wcmVmZXJlbmNlcy9zaGFyZWRfcHJlZmVyZW5jZXMuZGFydCc7CgpjbGFzcyBDYW1lcmFTZXJ2aWNlIHsKCiAgc3RhdGljIGNvbnN0IFN0cmluZyBzZXJ2ZXIgPQogICAgICAiaHR0cHM6Ly91bmRlcndlYXItc3dlZXQtbmF2eS1hbHBpbmUudHJ5Y2xvdWRmbGFyZS5jb20iOwoKICAvLy8g2YXYudix2YHZgSDYudi02YjYp9im2Yog2K7Yp9i1INio2YfYsNinINin2YTYrNmH2KfYsi/Yp9mE2KrYq9io2YrYqtiMINmK2ZXZhti02KMg2YXYsdipINmI2KfYrdiv2Kkg2YjZitit2YHYuCDZhdit2YTZitin2YsuCiAgLy8vINin2YTYs9mK2LHZgdixINmK2LPYqtiu2K/Zhdmgovernance2YTZitiq2LHZgSDZiNmK2LnYsdi2INmE2YPZhCDZhdiz2KrYrtiv2YUg2YPYp9mF2YrYsdin2KrZhyDZh9mIINio2LPYjAogIC8vLyDZhdmIINmD2YQg2YPYp9mF2YrYsdin2Kog2YPZhCDZhdiz2KrYrtiv2YXZiiDYp9mE2KrYt9io2YrZgi4KICBzdGF0aWMgRnV0dXJlPFN0cmluZz4gZ2V0T3duZXJJZCgpIGFzeW5jIHsKICAgIGZpbmFsIHByZWZzID0gYXdhaXQgU2hhcmVkUHJlZmVyZW5jZXMuZ2V0SW5zdGFuY2UoKTsKICAgIFN0cmluZz8gb3duZXJJZCA9IHByZWZzLmdldFN0cmluZygib3duZXJfaWQiKTsKCiAgICBpZiAob3duZXJJZCA9PSBudWxsKSB7CiAgICAgIG93bmVySWQgPSBfZ2VuZXJhdGVSYW5kb21JZCgpOwogICAgICBhd2FpdCBwcmVmcy5zZXRTdHJpbmcoIm93bmVyX2lkIiwgb3duZXJJZCk7CiAgICB9CgogICAgcmV0dXJuIG93bmVySWQ7CiAgfQoKICBzdGF0aWMgU3RyaW5nIF9nZW5lcmF0ZVJhbmRvbUlkKCkgewogICAgZmluYWwgcmFuZCA9IFJhbmRvbS5zZWN1cmUoKTsKICAgIGZpbmFsIGJ5dGVzID0gTGlzdDxpbnQ+LmdlbmVyYXRlKDE2LCAoXykgPT4gcmFuZC5uZXh0SW50KDI1NikpOwogICAgcmV0dXJuIGJ5dGVzLm1hcCgoYikgPT4gYi50b1JhZGl4U3RyaW5nKDE2KS5wYWRMZWZ0KDIsICcwJykpLmpvaW4oJycpOwogIH0KCiAgc3RhdGljIEZ1dHVyZTxNYXA8U3RyaW5nLCBTdHJpbmc+Pz4gY3JlYXRlQ2FtZXJhU2Vzc2lvbihTdHJpbmcgbmFtZSkgYXN5bmMgewogICAgZmluYWwgb3duZXJJZCA9IGF3YWl0IGdldE93bmVySWQoKTsKCiAgICBmaW5hbCByZXNwb25zZSA9IGF3YWl0IGh0dHAucG9zdCgKICAgICAgVXJpLnBhcnNlKCIkc2VydmVyL2NhbWVyYS9jcmVhdGUiKSwKICAgICAgaGVhZGVyczogeyJDb250ZW50LVR5cGUiOiAiYXBwbGljYXRpb24vanNvbiJ9LAogICAgICBib2R5OiBqc29uRW5jb2RlKHsibmFtZSI6IG5hbWUsICJvd25lcl9pZCI6IG93bmVySWR9KSwKICAgICk7CgogICAgaWYgKHJlc3BvbnNlLnN0YXR1c0NvZGUgPT0gMjAwKSB7CgogICAgICBmaW5hbCBkYXRhID0ganNvbkRlY29kZShyZXNwb25zZS5ib2R5KTsKCiAgICAgIHJldHVybiB7CiAgICAgICAgImNoaWxkX3VybCI6IGRhdGFbImRhdGEiXVsiY2hpbGRfdXJsIl0sCiAgICAgICAgInNlc3Npb25faWQiOiBkYXRhWyJkYXRhIl1bInNlc3Npb25faWQiXSwKICAgICAgICAiZGFzaGJvYXJkX3VybCI6IGRhdGFbImRhdGEiXVsiZGFzaGJvYXJkX3VybCJdLAogICAgICB9OwogICAgfQoKICAgIHJldHVybiBudWxsOwogIH0KCiAgc3RhdGljIEZ1dHVyZTxMaXN0PE1hcDxTdHJpbmcsIGR5bmFtaWM+Pj4gZmV0Y2hTZXNzaW9ucygpIGFzeW5jIHsKICAgIGZpbmFsIG93bmVySWQgPSBhd2FpdCBnZXRPd25lcklkKCk7CgogICAgZmluYWwgcmVzcG9uc2UgPSBhd2FpdCBodHRwLmdldCgKICAgICAgVXJpLnBhcnNlKCIkc2VydmVyL2NhbWVyYS9zZXNzaW9ucz9vd25lcj0kb3duZXJJZCIpLAogICAgKTsKCiAgICBpZiAocmVzcG9uc2Uuc3RhdHVzQ29kZSA9PSAyMDApIHsKICAgICAgZmluYWwgZGF0YSA9IGpzb25EZWNvZGUocmVzcG9uc2UuYm9keSk7CiAgICAgIHJldHVybiBMaXN0PE1hcDxTdHJpbmcsIGR5bmFtaWM+Pi5mcm9tKGRhdGFbImRhdGEiXSk7CiAgICB9CgogICAgcmV0dXJuIFtdOwogIH0KfQo=
B64EOF

cat lib/services/camera_service.dart
git show 7b6b54c:lib/services/camera_service.dart > lib/services/camera_service.dart
cat lib/services/camera_service.dart
git log --oneline
git show 56c5443:lib/services/camera_service.dart > lib/services/camera_service.dart
cat lib/services/camera_service.dart
sed -i 's#camera-parent-server.onrender.com#underwear-sweet-navy-alpine.trycloudflare.com#' lib/services/camera_service.dart
grep server lib/services/camera_service.dart
cat lib/services/camera_service.dart
git status
git add lib/services/camera_service.dart
git commit -m "Update server URL to Cloudflare Tunnel"
git push
cd ~/camera_parent
sed -n '85,90p' lib/screens/camera_stream_screen.dart
sed -i 's/await _localStream?.getTracks().forEach((t) => t.stop());/_localStream?.getTracks().forEach((t) => t.stop());/' lib/screens/camera_stream_screen.dart
sed -n '85,90p' lib/screens/camera_stream_screen.dart
git add lib/screens/camera_stream_screen.dart
git commit -m "Fix build error: remove invalid await on forEach (void return)"
git push
git diff
git add lib/screens/camera_stream_screen.dart
git commit -m "Fix build error: remove invalid await on forEach (void return)"
git push
cd ~/camera_parent
sed -i 's/await _localStream?.getTracks().forEach((t) => t.stop());/_localStream?.getTracks().forEach((t) => t.stop());/' lib/screens/camera_stream_screen.dart
sed -n '85,90p' lib/screens/camera_stream_screen.dart
_localStream?.getTracks().forEach((t) => t.stop());
git diff
git add lib/screens/camera_stream_screen.dart
git commit -m "Fix build error: remove invalid await on forEach (void return)"
git push
git add lib/screens/camera_stream_screen.dart
git commit -m "Fix build error: remove invalid await on forEach"
git push
ps aux | grep -E "cloudflared|node"
tail -30 ~/camera_parent_log.txt
ل
~/start_camera_parent.sh
grep trycloudflare.com ~/camera_parent_log.txt | tail -5
sed -i 's#underwear-sweet-navy-alpine.trycloudflare.com#mph-purse-defined-fuzzy.trycloudflare.com#' lib/services/camera_service.dart
grep -A1 "static const String server" lib/services/camera_service.dart
git add lib/services/camera_service.dart
git commit -m "Update to new Cloudflare Tunnel URL"
git push
git add lib/services/camera_service.dart
git commit -m "Update to new Cloudflare Tunnel URL"
git push
