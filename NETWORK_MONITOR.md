
# Network Monitor

Added network state monitoring layer.

Flow:

NetworkCallback
 -> NetworkMonitor
 -> RecoveryController
 -> StreamManager

Events:
- NETWORK_AVAILABLE
- NETWORK_LOST

Next step:
connect callbacks to RecoveryQueue.
