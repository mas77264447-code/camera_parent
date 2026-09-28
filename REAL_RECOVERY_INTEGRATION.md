
# Real Recovery Integration

Connected:
- StreamManager
- WebRTCSessionManager
- Recovery flow

Added:
- pauseForNetworkLoss()
- reconnectSignaling()
- restoreSessionAndIce()
- verifyStream()

Test:
1. Start stream
2. Disable network
3. Enable network
4. Check Logcat recovery sequence
