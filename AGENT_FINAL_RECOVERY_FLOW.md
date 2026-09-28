
# AgentService Final Recovery Flow

ConnectivityMethodChannel
        |
        v
AgentService
        |
        v
RecoveryQueue.instance
        |
        v
StreamManager

Recovery steps:
1. reconnect()
2. restoreSessionAndIce()
3. rebuildAllPeerConnections()
4. verifyStream()

Queue prevents duplicate recovery executions.
