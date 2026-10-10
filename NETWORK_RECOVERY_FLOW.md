
# Network Recovery Flow

NetworkMonitor
      |
      v
NetworkRecoveryController
      |
      +-- Save Session
      +-- WebSocket reconnect
      +-- Restore WebRTC
      +-- Rebuild PeerConnection
      +-- Verify Stream

States:
- idle
- waitingNetwork
- recovering
- restored
