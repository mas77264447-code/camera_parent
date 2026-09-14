
import 'dart:async';

enum NetworkStatus {
  available,
  lost,
  unknown,
}

class NetworkMonitor {
  NetworkMonitor._();

  static final instance = NetworkMonitor._();

  NetworkStatus status = NetworkStatus.unknown;

  final StreamController<NetworkStatus> _controller =
      StreamController<NetworkStatus>.broadcast();

  Stream<NetworkStatus> get onStatusChanged => _controller.stream;

  void update(NetworkStatus value) {
    status = value;
    _controller.add(value);
  }

  bool get isOnline => status == NetworkStatus.available;

  void dispose() {
    _controller.close();
  }
}
