import 'connection_state_manager.dart';

typedef RecoveryTask = Future<void> Function();

class RecoveryQueue {
  RecoveryQueue._();

  static final RecoveryQueue instance = RecoveryQueue._();

  bool _running = false;
  final List<RecoveryTask> _queue = [];

  bool get isRunning => _running;

  Future<void> enqueue(RecoveryTask task) async {
    _queue.add(task);
    if (!_running) {
      await _process();
    }
  }

  Future<void> _process() async {
    _running = true;
    ConnectionStateManager.instance.update(ConnectionStatus.reconnecting);

    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeAt(0);
        try {
          await task();
          ConnectionStateManager.instance.update(ConnectionStatus.connected);
        } catch (_) {
          ConnectionStateManager.instance.update(ConnectionStatus.failed);
        }
      }
    } finally {
      _running = false;
      if (_queue.isEmpty &&
          ConnectionStateManager.instance.status == ConnectionStatus.reconnecting) {
        ConnectionStateManager.instance.update(ConnectionStatus.idle);
      }
    }
  }
}
