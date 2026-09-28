
import 'network_recovery_controller.dart';

class NetworkRecoveryIntegration {
  final dynamic streamManager;
  final dynamic recoveryQueue;
  final dynamic sessionManager;

  NetworkRecoveryIntegration({
    required this.streamManager,
    required this.recoveryQueue,
    required this.sessionManager,
  });

  Future<void> onNetworkLost() async {
    // Save current WebRTC state before recovery pause
    await sessionManager.saveCurrentSession();

    streamManager.pauseForNetworkLoss();
  }

  Future<void> onNetworkRestored() async {
    await recoveryQueue.enqueue(() async {

      // 1. Reconnect signaling
      await streamManager.reconnectSignaling();

      // 2. Restore saved WebRTC session
      final session = await sessionManager.loadSession();

      if (session != null) {
        await streamManager.restoreSession(session);
      }

      // 3. Rebuild PeerConnection if required
      await streamManager.rebuildPeerConnection();

      // 4. Restore ICE candidates
      await sessionManager.restoreIceCandidates(
        streamManager.peerConnection,
      );

      // 5. Verify stream health
      await streamManager.verifyStream();

    });
  }
}
