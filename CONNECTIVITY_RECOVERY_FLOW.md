
# Connectivity Listener Recovery

Flow:

ConnectivityManager
        |
        v
NetworkConnectivityListener
        |
        +--> LOST
        |       Save Session
        |       Pause Recovery
        |
        +--> AVAILABLE
                Immediate Reconnect
                Restore Session
                Rebuild PeerConnection
                Restore ICE

Heartbeat remains as health check only.
