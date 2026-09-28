
# ConnectionStatus + RecoveryQueue

Prevents duplicate recovery.

If status == reconnecting:
- Ignore new recovery requests.

Flow:

Network Event
 |
 v
RecoveryQueue
 |
 v
ConnectionStatus = reconnecting
 |
 v
Reconnect
 |
 v
Restore Session
 |
 v
Rebuild PeerConnection
 |
 v
ConnectionStatus = connected
