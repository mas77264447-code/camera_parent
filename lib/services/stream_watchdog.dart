import 'dart:async';

/// Lightweight watchdog for connection/media health.
/// It does not bypass Android safeguards or restart media permissions.
class StreamWatchdog {
  Timer? _timer;
  bool healthy = true;
  int _unhealthyTicks = 0;
  DateTime? _lastHealthyAt;
  FutureOr<void> Function()? onUnhealthy;

  bool get isRunning => _timer != null;
  DateTime? get lastHealthyAt => _lastHealthyAt;
  int get unhealthyTicks => _unhealthyTicks;

  void start({
    Duration interval = const Duration(seconds: 15),
    required bool Function() healthCheck,
    FutureOr<void> Function()? onUnhealthy,
  }) {
    stop();
    this.onUnhealthy = onUnhealthy;
    _lastHealthyAt = DateTime.now();
    _timer = Timer.periodic(interval, (_) async {
      if (healthCheck()) {
        healthy = true;
        _unhealthyTicks = 0;
        _lastHealthyAt = DateTime.now();
        return;
      }

      healthy = false;
      _unhealthyTicks++;
      if (_unhealthyTicks >= 2 && this.onUnhealthy != null) {
        await this.onUnhealthy!();
      }
    });
  }

  void markHealthy() {
    healthy = true;
    _unhealthyTicks = 0;
    _lastHealthyAt = DateTime.now();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    onUnhealthy = null;
  }
}
