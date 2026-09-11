
import 'network_monitor.dart';
import 'recovery_queue.dart';
import 'stream_watchdog.dart';
import 'stream_manager.dart';

class StabilityController {
  StabilityController._();
  static final StabilityController instance = StabilityController._();

  final RecoveryQueue recoveryQueue = RecoveryQueue();
  final NetworkMonitor networkMonitor = NetworkMonitor();
  final StreamWatchdog watchdog = StreamWatchdog();

  final StreamManager stream = StreamManager.instance;

  bool running = false;

  void start() {
    if (running) return;
    running = true;

    networkMonitor.start(
      onAvailable: () => requestRecovery(),
      onLost: () {},
    );
  }

  Future<void> requestRecovery() async {
    await recoveryQueue.enqueue(() async {
      if (!stream.isWebSocketConnected()) {
        await stream.reconnect();
      }
      if (!stream.hasActivePeerConnection()) {
        await stream.recoverWebRTC();
      }
    });
  }

  void stop() {
    running = false;
    networkMonitor.stop();
  }
}
