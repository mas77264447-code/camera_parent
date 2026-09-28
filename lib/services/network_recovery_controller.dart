
import 'network_monitor.dart';

enum RecoveryState {
  idle,
  waitingNetwork,
  recovering,
  restored,
}

class NetworkRecoveryController {
  NetworkRecoveryController._();

  static final instance = NetworkRecoveryController._();

  RecoveryState state = RecoveryState.idle;

  void onNetworkLost() {
    state = RecoveryState.waitingNetwork;
  }

  Future<void> onNetworkAvailable() async {
    if (state != RecoveryState.waitingNetwork) return;

    state = RecoveryState.recovering;

    // Connect this point with:
    // 1- WebSocket reconnect
    // 2- Restore WebRTC session
    // 3- Rebuild PeerConnection
    // 4- Verify media

    state = RecoveryState.restored;
  }

  void bind(NetworkMonitor monitor) {
    monitor.onStatusChanged.listen((status) async {
      if (status == NetworkStatus.lost) {
        onNetworkLost();
      } else if (status == NetworkStatus.available) {
        await onNetworkAvailable();
      }
    });
  }
}
