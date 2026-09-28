# Camera recovery after removing the app from Recents

The Camera build uses an Android foreground service for the active camera stream.

## What happens when the user presses X in Recent Apps?

- `StreamForegroundService` is declared with `android:stopWithTask="false"`.
- The camera service returns `START_STICKY` while it is enabled.
- `onTaskRemoved()` does **not** stop the camera service.
- If Android later kills the service process for a normal system reason, Android may recreate the sticky service.
- The Dart/WebSocket recovery layer can then reconnect the stream.

## Why the watchdog does not directly restart the camera service

Modern Android restricts starting camera/microphone foreground services from the
background. An AlarmManager receiver is not a safe way to bypass those rules.
The watchdog therefore records a lightweight heartbeat only; it never attempts a
background camera/microphone FGS start.

This avoids `ForegroundServiceStartNotAllowedException`/`SecurityException` on
newer Android versions and leaves service lifecycle recovery to Android's
foreground-service rules.

## Reboot

Android 14/15+ restricts launching camera, microphone, and mediaProjection
foreground services from `BOOT_COMPLETED`. The app therefore does not attempt to
silently restart camera capture at boot. The user can open Camera and start a new
session normally.

## Force Stop

Android intentionally prevents an app from defeating **Force Stop**. This build
does not attempt to bypass that system control.
