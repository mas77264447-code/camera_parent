import 'recovery_queue.dart';

class WebRTCRecoveryPipeline {
  final dynamic streamManager;

  WebRTCRecoveryPipeline({
    required this.streamManager,
  });

  Future<void> startRecovery() async {
    await RecoveryQueue.instance.enqueue(() async {
      await streamManager.reconnectSignaling();
      await streamManager.restoreSessionAndIce();
      // The screen registers the real PeerConnection recovery handlers.
      // Do not rebuild the same connection through a second nested queue.
      await streamManager.recoverWebRTC();
      await streamManager.verifyStream();
    });
  }
}
