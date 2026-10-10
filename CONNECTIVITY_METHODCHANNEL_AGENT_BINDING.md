
# ConnectivityMethodChannel Agent Binding

Android event:
networkChanged(false/true)

Flutter:
ConnectivityMethodChannel

Agent:
AgentConnectivityBinding

Network lost:
- pauseForNetworkLoss()
- saveRecoverySnapshot()

Network available:
- RecoveryQueue
- reconnect()
- restoreSessionAndIce()
- rebuildAllPeerConnections()
