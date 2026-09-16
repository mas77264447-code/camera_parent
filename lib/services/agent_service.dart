import 'dart:async';

import 'recovery_queue.dart';
import 'stream_manager.dart';
import 'stability_controller.dart';

/// Background recovery coordinator.
///
/// Important: the actual WebSocket/PeerConnections are owned by
/// CameraStreamScreen. Do not create a second signaling WebSocket here.
class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  Timer? _heartbeat;
  bool running = false;
  bool _heartbeatInFlight = false;

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

    unawaited(heartbeat());
  }

  Future<void> heartbeat() async {
    if (!running || _heartbeatInFlight) return;
    _heartbeatInFlight = true;

    try {
      // CameraStreamScreen owns the actual PeerConnections and their
      // recovery handlers. Only recover an explicitly broken connection;
      // CONNECTING/NEW are not failures.
      if (streamManager.hasRecoverablePeerConnection()) {
        await RecoveryQueue.instance.enqueue(() async {
          await streamManager.recoverWebRTC();
        }, key: 'stream-recovery');
      }
    } catch (_) {
      // Recovery is retried on the next heartbeat or network event.
    } finally {
      _heartbeatInFlight = false;
    }
  }

  void stop() {
    running = false;
    stability.stop();
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}

