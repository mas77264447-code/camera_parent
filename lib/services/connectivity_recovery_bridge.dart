
class ConnectivityRecoveryBridge {

  final dynamic agentService;
  final dynamic recoveryQueue;
  final dynamic streamManager;

  bool _recovering = false;

  ConnectivityRecoveryBridge({
    required this.agentService,
    required this.recoveryQueue,
    required this.streamManager,
  });


  Future<void> onNetworkLost() async {
    if (_recovering) return;

    await streamManager.pauseStream();

    await streamManager.saveSession();
  }


  Future<void> onNetworkAvailable() async {
    if (_recovering) return;

    _recovering = true;

    try {
      await recoveryQueue.enqueue(() async {

        await streamManager.startRecovery();

        await streamManager.rebuildPeerConnection();

        await streamManager.verifyStream();

      });

    } finally {
      _recovering = false;
    }
  }
}
