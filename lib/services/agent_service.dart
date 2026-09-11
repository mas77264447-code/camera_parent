import 'recovery_queue.dart';

import 'dart:async';
import 'stream_manager.dart';
import 'stability_controller.dart';

class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  Timer? _heartbeat;
  bool running = false;

  final StreamManager streamManager = StreamManager.instance;
  final StabilityController stability = StabilityController.instance;

  void start() {
    if (running) return;
    running = true;
    stability.start();

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => heartbeat(),
    );

    heartbeat();
  }

  Future<void> heartbeat() async {
    if (!running) return;
    try {
      if (!streamManager.isWebSocketConnected()) {
        await streamManager.reconnect();
      }

      if (!streamManager.hasActivePeerConnection()) {
        await streamManager.recoverWebRTC();
        await stability.requestRecovery();
      }
    } catch (_) {}
  }

  void stop() {
    running = false;
    stability.stop();
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}


// RecoveryQueue integration
extension AgentRecoveryQueueIntegration on AgentService {

  Future<void> runWebRTCRecovery(
      dynamic streamManager
  ) async {

    await RecoveryQueue.instance.enqueue(() async {

      await streamManager.reconnectSignaling();
      await streamManager.restoreSessionAndIce();
      await streamManager.recoverWebRTC();
      await streamManager.verifyStream();

    });
  }
}
