# Recovery Hardening Report

This revision strengthens the existing WebRTC recovery architecture without bypassing Android permissions or media-projection consent.

## Changes
- Added a recovery state model with phase, attempt, success and failure counters.
- Added serialized recovery telemetry to the diagnostics screen.
- Kept stale SDP/ICE out of the persistent recovery marker; a recovered connection must negotiate fresh SDP/ICE.
- Added generation guards around viewer signaling sockets so an older socket cannot mutate current state.
- Added early-ICE queuing on both broadcaster and viewer paths.
- Added cleanup of per-peer pending ICE during disconnect/rebuild.
- Kept exponential backoff and single-flight recovery behavior.
- Kept watchdog behavior visible and bounded.

## Verification
- ZIP integrity checked with Python zipfile testzip(): PASS.
- SHA-256 is recalculated after packaging.
- Flutter/Dart SDK is not installed in this environment, so `flutter analyze` and APK compilation must still be performed by GitHub Actions.

## Android policy
The revision does not add hidden camera/microphone use, permission bypass, MediaProjection bypass, or stealth behavior.
