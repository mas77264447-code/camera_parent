
# Agent Connectivity Recovery

networkChanged(false)
 -> AgentService
 -> pauseStream()
 -> saveSession()

networkChanged(true)
 -> RecoveryQueue
 -> startRecovery()
 -> rebuildPeerConnection()
 -> restore ICE
 -> verifyStream
