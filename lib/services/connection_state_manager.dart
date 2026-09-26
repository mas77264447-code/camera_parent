
enum ConnectionStatus {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
}

class ConnectionStateManager {
  ConnectionStateManager._();

  static final instance = ConnectionStateManager._();

  ConnectionStatus _status = ConnectionStatus.idle;

  ConnectionStatus get status => _status;

  void update(ConnectionStatus value) {
    _status = value;
  }

  bool get isReconnecting =>
      _status == ConnectionStatus.reconnecting;
}
