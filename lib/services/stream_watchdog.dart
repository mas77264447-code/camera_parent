
import 'dart:async';

class StreamWatchdog {
  Timer? _timer;
  bool healthy = true;

  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) {
        // Hook for media frame/audio health checks.
      },
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
