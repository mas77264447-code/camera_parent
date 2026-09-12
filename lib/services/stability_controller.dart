import 'dart:async';

import 'recovery_queue.dart';
import 'stream_manager.dart';

class StabilityController {
  StabilityController._();
  static final StabilityController instance = StabilityController._();

  final RecoveryQueue recoveryQueue = RecoveryQueue.instance;
  final StreamManager stream = StreamManager.instance;

  Timer? _pollTimer;
  bool running = false;
  bool _recoveryInFlight = false;

  void start() {
    if (running) return;
    running = true;

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(requestRecovery()),
    );
  }

  Future<void> requestRecovery() async {
    if (!running || _recoveryInFlight) return;
    if (stream.peerConnections.isEmpty) return;
    if (stream.hasActivePeerConnection()) return;

    _recoveryInFlight = true;
    try {
      await recoveryQueue.enqueue(() async {
        await stream.closeDeadConnections();
        if (stream.peerConnections.isNotEmpty &&
            !stream.hasActivePeerConnection()) {
          await stream.recoverWebRTC();
        }
      });
    } finally {
      _recoveryInFlight = false;
    }
  }

  void stop() {
    running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}
