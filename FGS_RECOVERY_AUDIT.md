# Foreground Service Recovery Audit

This revision hardens the Camera/Screen foreground-service lifecycle without bypassing Android privacy or background-start restrictions.

## Changes
- `StreamForegroundService`: immediate `startForeground`, explicit camera/screen modes, idempotent recovery state, delayed Flutter bridge replaced by retry/ready polling, and cleanup of callbacks.
- `FlutterServiceBridge`: reports whether the persistent Flutter engine exists so the service can retry instead of racing a fixed 300 ms delay.
- `BootReceiver`: preserves recovery state and shows a user-visible recovery notification when Android 14+ blocks boot-time camera/microphone/MediaProjection FGS starts.
- Screen/MediaProjection consent is never recreated or bypassed.
- Camera mode remains eligible for normal Android `START_STICKY` service lifecycle; OEM battery/autostart policies can still affect it.

## Expected behavior
1. User explicitly starts Camera and grants required permissions.
2. Foreground Service starts immediately and displays its ongoing notification.
3. Flutter agent startup is retried until the persistent engine is ready.
4. Removing the recent-app task does not intentionally stop Camera mode.
5. After reboot, Android 14+ may defer camera/microphone FGS startup; the app keeps a recovery-pending state and presents a notification to continue through the normal Android-approved path.
