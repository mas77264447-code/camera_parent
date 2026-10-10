# RTCPeerConnection CLOSED recovery fix

This build changes recovery from a monitoring-only path into a real WebRTC rebuild path.

## What changed

- `CameraStreamScreen` now observes `RTCPeerConnectionState`.
- `CLOSED` and `FAILED` trigger a serialized recovery task.
- The stale PeerConnection is explicitly closed and removed.
- A new PeerConnection is created for the same `viewerId`.
- The current local media tracks are added to the new PeerConnection.
- A fresh SDP offer is created and sent through the existing signaling WebSocket.
- `StreamManager` now registers the real PeerConnection and its recovery callback instead of maintaining an unrelated recovery-only map.
- Recovery waits for signaling to be online before sending the new offer.
- Duplicate `viewer-joined` events are ignored while that viewer is already being recovered.
- `RecoveryQueue` no longer drops recovery requests merely because its state is `reconnecting`.
- `WebRTCRecoveryPipeline` and `AgentService` use the real registered recovery handlers rather than attempting to revive a CLOSED object with `restartIce()`.
- Added `[PC]`, `[ICE]`, and `[Recovery]` logs around the recovery path.

## Expected Logcat sequence after a fatal connection

```text
[PC] viewer=<id> state=...Closed
[Recovery] fatal PC state for viewer=<id> -> rebuild
[Recovery] START viewer=<id>
[Recovery] creating offer for viewer=<id>
[Recovery] offer sent viewer=<id>
[Recovery] COMPLETE viewer=<id>
[PC] viewer=<id> state=...
[ICE] viewer=<id> state=...
```

The final successful states should include a connected/complete WebRTC state and media should return on the viewer.

## Verification note

The project was modified and structurally checked in this environment, but Flutter/Dart SDK is not installed here, so a local `flutter analyze`/APK build was not possible. Real-device verification still requires installing this build and checking Logcat.
