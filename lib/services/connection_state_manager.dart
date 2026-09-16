import 'dart:async';

enum ConnectionStatus {
  idle,
  connecting,
  connected,
  networkLost,
  reconnecting,
  negotiating,
  failed,
}

class ConnectionStateManager {
  ConnectionStateManager._();

  static final instance = ConnectionStateManager._();

  ConnectionStatus _status = ConnectionStatus.idle;
  DateTime? _changedAt;
  String? _detail;
  final StreamController<ConnectionStatus> _changes =
      StreamController<ConnectionStatus>.broadcast();

  ConnectionStatus get status => _status;
  DateTime? get changedAt => _changedAt;
  String? get detail => _detail;
  Stream<ConnectionStatus> get changes => _changes.stream;

  void update(ConnectionStatus value, {String? detail}) {
    _status = value;
    _detail = detail;
    _changedAt = DateTime.now();
    if (!_changes.isClosed) _changes.add(value);
  }

  bool get isReconnecting =>
      _status == ConnectionStatus.networkLost ||
      _status == ConnectionStatus.reconnecting ||
      _status == ConnectionStatus.negotiating;
}
