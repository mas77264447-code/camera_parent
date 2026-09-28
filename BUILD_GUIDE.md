# Camera Parent — Android Studio & GitHub Actions

## Android Studio
1. Install Android Studio with Android SDK, SDK Platform Tools, Android SDK Build Tools, and JDK 17.
2. Open the project **root folder** (the folder containing `pubspec.yaml`), not the `android` subfolder.
3. Let Android Studio finish Gradle/Flutter sync.
4. If `local.properties` is missing, run `flutter pub get` from the Flutter terminal; Flutter will create it.
5. Select a device/emulator and run the desired flavor.

### Flavors
- Parent: `parent` → application ID `com.example.camera_parent.parent` → Camera Parent
- Child: `child` → application ID `com.example.camera_parent.child` → Camera

The two APKs are independently installable because their application IDs are different.

## GitHub Actions
The workflow `.github/workflows/build-apk.yml` builds both flavors on pushes to `main` and on manual runs. It uploads two separate artifacts:
- `camera-parent-app-apk`
- `camera-child-app-apk`

The workflow uses Flutter 3.44.0 and Java 17.

## Important Android behavior
- Camera streaming uses foreground-service types `camera|microphone`.
- Screen streaming switches the foreground service to `mediaProjection` **after** the user grants Android screen-capture consent.
- Screen capture permission is still controlled by Android; an ordinary APK cannot silently obtain or retain unrestricted screen capture across reboots.
- Device Owner/Kiosk requires Android device-management provisioning; Device Admin alone is not Device Owner.
