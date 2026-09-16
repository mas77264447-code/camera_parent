import 'dart:async';

import 'connection_state_manager.dart';
import 'recovery_state.dart';

typedef RecoveryTask = Future<void> Function();

/// Single serialized recovery pipeline used by network, heartbeat and UI recovery.
/// A key prevents the same recovery reason from being queued more than once.
class RecoveryQueue {
  RecoveryQueue._();

  static final RecoveryQueue instance = RecoveryQueue._();

  bool _running = false;
  final List<_QueuedTask> _queue = <_QueuedTask>[];
  final Set<String> _keys = <String>{};

  bool get isRunning => _running;

  /// Runs inline when called from an already-running recovery pipeline.
  /// This avoids a deadlock when the global recovery asks a per-peer handler
  /// to recover and that handler would otherwise enqueue and await another task.
  Future<void> runOrEnqueue(RecoveryTask task, {String? key}) async {
    if (_running) {
      await task();
      return;
    }
    await enqueue(task, key: key);
  }

  Future<void> enqueue(RecoveryTask task, {String? key}) async {
    if (key != null && !_keys.add(key)) return;

    final completer = Completer<void>();
    _queue.add(_QueuedTask(task, key, completer));
    if (!_running) {
      unawaited(_process());
    }
    return completer.future;
  }

  Future<void> _process() async {
    if (_running) return;
    _running = true;
    RecoveryState.instance.startedAttempt();
    ConnectionStateManager.instance.update(ConnectionStatus.reconnecting);

    try {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        try {
          await item.task();
          if (!item.completer.isCompleted) item.completer.complete();
          RecoveryState.instance.markSuccess(detail: 'recovery task complete');
          if (ConnectionStateManager.instance.status == ConnectionStatus.negotiating ||
              ConnectionStateManager.instance.status == ConnectionStatus.reconnecting) {
            ConnectionStateManager.instance.update(ConnectionStatus.connected);
          }
        } catch (e, st) {
          if (!item.completer.isCompleted) {
            item.completer.completeError(e, st);
          }
          RecoveryState.instance.markFailure(e);
          ConnectionStateManager.instance.update(ConnectionStatus.failed);
        } finally {
          if (item.key != null) _keys.remove(item.key);
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

class _QueuedTask {
  _QueuedTask(this.task, this.key, this.completer);
  final RecoveryTask task;
  final String? key;
  final Completer<void> completer;
}
