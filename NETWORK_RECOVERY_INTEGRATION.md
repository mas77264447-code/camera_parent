
# Network Recovery Integration

Flow:

NetworkRecoveryController
        |
        v
NetworkRecoveryIntegration
        |
        +--> StreamManager
        |       - reconnect signaling
        |       - rebuild PeerConnection
        |       - verify stream
        |
        +--> RecoveryQueue
        |       - prevent duplicate recovery
        |
        +--> WebRTCSessionManager
                - save session
                - restore ICE

Result:
Network loss -> save -> reconnect -> restore -> rebuild -> stream verify
