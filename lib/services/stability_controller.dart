import 'dart:async';

import 'network_monitor.dart';
import 'recovery_queue.dart';
import 'connection_state_manager.dart';

class StabilityController {
  StabilityController._();

  static final StabilityController instance =
      StabilityController._();

  final RecoveryQueue recoveryQueue = RecoveryQueue.instance;
  final NetworkMonitor networkMonitor = NetworkMonitor.instance;

  StreamSubscription? _networkSubscription;

  void initialize() {
    _networkSubscription ??=
        networkMonitor.onStatusChanged.listen(
      (status) {
        if (status == NetworkStatus.lost) {
          _handleNetworkLost();
        }

        if (status == NetworkStatus.available) {
          _handleNetworkRestored();
        }
      },
    );
  }

  void _handleNetworkLost() {
    ConnectionStateManager.instance
        .update(ConnectionStatus.reconnecting);
  }

  void _handleNetworkRestored() {
    if (recoveryQueue.isRunning) {
      return;
    }

    recoveryQueue.enqueue(() async {
      // Recovery pipeline placeholder
      //
      // سيتم ربط:
      // WebRTCSessionManager.rebuildPeerConnection()
      // StreamManager.restoreSession()
    });
  }


  // ==============================
  // Compatibility API
  // AgentService يستخدم هذه الدوال
  // ==============================

  void start() {
    initialize();
  }


  Future<void> requestRecovery() async {
    if (recoveryQueue.isRunning) {
      return;
    }

    await recoveryQueue.enqueue(() async {
      // Recovery execution
      //
      // سيتم تنفيذ:
      // إعادة بناء PeerConnection
      // استرجاع Stream Session
    });
  }


  void stop() {
    dispose();
  }


  void dispose() {
    _networkSubscription?.cancel();
    _networkSubscription = null;
  }
}