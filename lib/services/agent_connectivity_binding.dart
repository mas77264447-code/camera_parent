
import 'connectivity_method_channel.dart';

class AgentConnectivityBinding {
  final dynamic streamManager;
  final dynamic recoveryQueue;

  AgentConnectivityBinding({
    required this.streamManager,
    required this.recoveryQueue,
  });

  void initialize() {
    ConnectivityMethodChannel.initialize(
      onNetworkChanged: _handleNetwork,
    );
  }

  Future<void> _handleNetwork(bool online) async {
    if (!online) {
      await streamManager.pauseForNetworkLoss();
      await streamManager.sessionManager.saveRecoverySnapshot();
      return;
    }

    await recoveryQueue.enqueue(() async {
      await streamManager.reconnect();
      await streamManager.restoreSessionAndIce();
      await streamManager.rebuildAllPeerConnections();
    });
  }
}
