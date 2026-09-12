
# Connectivity Agent Recovery Integration

NetworkConnectivityListener events:

NETWORK_LOST
 |
 v
AgentService
 |
 v
pauseStream()
 |
 v
saveSession()


NETWORK_AVAILABLE
 |
 v
RecoveryQueue
 |
 v
startRecovery()
 |
 v
rebuildPeerConnection()
 |
 v
verifyStream()

Heartbeat remains health monitoring only.
