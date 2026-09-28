# Recovery architecture

There is one serialized recovery pipeline: `RecoveryQueue`.

All recovery triggers use the same key, `stream-recovery`:

- native network availability changes
- heartbeat/stability checks
- future UI retry actions

`StreamManager.recoverSession()` is the only orchestration entry point. It performs:

1. reconnect signaling if needed
2. restore the saved session/ICE state
3. invoke registered PeerConnection recovery handlers
4. verify connection health

No recovery trigger creates a second WebSocket or runs an independent ICE recovery
loop. The queue coalesces duplicate requests while one recovery is already running.
