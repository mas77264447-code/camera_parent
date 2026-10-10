# Reliability Hardening v2

- Foreground Service keeps an explicit enabled state.
- `START_STICKY` remains enabled for OS recreation.
- `onTaskRemoved()` only requests a restart when the service was explicitly enabled.
- Explicit stop uses `START_NOT_STICKY` so a user stop is not immediately undone.
- Boot recovery restores the service only when it was previously enabled.
- AgentService no longer opens a second, disconnected signaling WebSocket.
- Recovery now delegates to the real PeerConnection handlers registered by `CameraStreamScreen`.
- Recovery/heartbeat calls are serialized to avoid overlapping rebuilds.
- Fixed StabilityController references to the singleton RecoveryQueue and NetworkMonitor API mismatch.
- The actual UI-owned WebSocket now has a connection-in-progress guard.

## Important limitation

This is Android lifecycle/recovery hardening, not a guarantee against force-stop, OEM task killers, reboot policy restrictions, or Android foreground-service restrictions. Actual WebRTC recovery still needs to be verified on the target device with Logcat/CI.
