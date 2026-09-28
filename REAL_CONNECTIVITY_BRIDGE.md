
# Real Connectivity Bridge

Android:
NetworkConnectivityListener
        |
        v
ConnectivityChannel
        |
        v
Flutter MethodChannel
        |
        v
AgentService
        |
        v
StreamManager

Events:
networkChanged(true)
networkChanged(false)

Use these events to call:
- pauseStream()
- saveSession()
- startRecovery()
- rebuildPeerConnection()
