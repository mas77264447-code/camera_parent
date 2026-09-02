import 'dart:async';

/// Agent background manager.
///
/// Keeps the application state ready for reconnect logic.
/// Android background execution still requires a native Foreground Service.
class AgentService {
  Timer? _heartbeat;
  bool running = false;

  void start() {
    if (running) return;
    running = true;

    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        // Hook for WebSocket heartbeat / reconnect.
      },
    );
  }

  void stop() {
    running = false;
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}
