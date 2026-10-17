
import 'connectivity_method_channel.dart';

class AgentConnectivityRecovery {
  final dynamic streamManager;
  final dynamic recoveryQueue;
  bool recovering = false;

  AgentConnectivityRecovery({
    required this.streamManager,
    required this.recoveryQueue,
  });

  void initialize() {
    ConnectivityMethodChannel.initialize(
      onNetworkChanged: (online) async {
        if (online) {
          await _networkRestored();
        } else {
          await _networkLost();
        }
      },
    );
  }

  Future<void> _networkLost() async {
    await streamManager.pauseStream();
    await streamManager.saveSession();
  }

  Future<void> _networkRestored() async {
    if (recovering) return;
    recovering = true;
    try {
      await recoveryQueue.enqueue(() async {
        await streamManager.startRecovery();
        await streamManager.rebuildPeerConnection();
        await streamManager.restoreIceCandidates();
        await streamManager.verifyStream();
      });
    } finally {
      recovering = false;
    }
  }
}
