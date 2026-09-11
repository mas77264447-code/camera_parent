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
      // هنا يتم ربط Recovery الحقيقي
      // WebRTCSessionManager.rebuildPeerConnection()
      // StreamManager.restoreSession()
    });
  }

  void dispose() {
    _networkSubscription?.cancel();
    _networkSubscription = null;
  }
}
