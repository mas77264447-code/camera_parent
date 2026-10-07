
# RecoveryQueue Real Project Binding

Uses project methods:

StreamManager:
- pauseForNetworkLoss()
- reconnect()
- restoreSessionAndIce()
- rebuildAllPeerConnections()
- verifyStream()

Flow:

Network Lost:
 pauseForNetworkLoss()
 saveRecoverySnapshot()

Network Available:
 RecoveryQueue
   -> reconnect()
   -> restoreSessionAndIce()
   -> rebuildAllPeerConnections()
   -> verifyStream()

Queue prevents duplicate recovery runs.
