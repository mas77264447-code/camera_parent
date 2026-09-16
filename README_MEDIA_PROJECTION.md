# MediaProjection / Android 14+ design

The app uses `flutter_webrtc` for the actual WebRTC screen capturer. Android's
MediaProjection consent is requested exactly once by the plugin.

After the user grants consent, the Android plugin code is patched at build time
to start `StreamForegroundService` with `mediaProjection` type. A short delay
allows the service to call `startForeground()` before WebRTC calls
`MediaProjectionManager.getMediaProjection()` internally.

The Flutter layer then calls `confirmScreenCapture`. If the WebRTC call fails or
never confirms the session, the service automatically stops after 10 seconds.

Do not add another native `MediaProjectionManager.createScreenCaptureIntent()`
flow to the app. Doing so would create a second consent/token path and can
violate Android 14+ single-session requirements.

Android requires a fresh user consent for each capture session and forbids
reusing the same projection instance for multiple virtual displays. The build
patch preserves that rule by using the exact Intent returned by flutter_webrtc
once, without caching or creating a second projection token.
