import 'dart:async';

enum RecoveryPhase {
  idle,
  networkLost,
  reconnecting,
  negotiating,
  iceConnecting,
  connected,
  failed,
}

class RecoveryState {
  RecoveryState._();
  static final instance = RecoveryState._();

  RecoveryPhase _phase = RecoveryPhase.idle;
  String? _detail;
  DateTime? _changedAt;
  int _attempt = 0;
  int _successes = 0;
  int _failures = 0;
  final _changes = StreamController<RecoveryStateSnapshot>.broadcast();

  RecoveryPhase get phase => _phase;
  String? get detail => _detail;
  DateTime? get changedAt => _changedAt;
  int get attempt => _attempt;
  int get successes => _successes;
  int get failures => _failures;
  Stream<RecoveryStateSnapshot> get changes => _changes.stream;

  void setPhase(RecoveryPhase phase, {String? detail}) {
    _phase = phase;
    _detail = detail;
    _changedAt = DateTime.now();
    _changes.add(snapshot);
  }

  void startedAttempt() {
    _attempt++;
    setPhase(RecoveryPhase.reconnecting, detail: 'attempt $_attempt');
  }

  void markSuccess({String? detail}) {
    _successes++;
    setPhase(RecoveryPhase.connected, detail: detail ?? 'recovery complete');
  }

  void markFailure(Object error) {
    _failures++;
    setPhase(RecoveryPhase.failed, detail: error.toString());
  }

  RecoveryStateSnapshot get snapshot => RecoveryStateSnapshot(
        phase: _phase,
        detail: _detail,
        changedAt: _changedAt,
        attempt: _attempt,
        successes: _successes,
        failures: _failures,
      );
}

class RecoveryStateSnapshot {
  const RecoveryStateSnapshot({
    required this.phase,
    required this.detail,
    required this.changedAt,
    required this.attempt,
    required this.successes,
    required this.failures,
  });

  final RecoveryPhase phase;
  final String? detail;
  final DateTime? changedAt;
  final int attempt;
  final int successes;
  final int failures;
}
