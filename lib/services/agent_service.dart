import 'dart:async';
import 'package:flutter/foundation.dart';

import 'stream_service.dart';

/// Heartbeat service — يتحقق كل 20 ثانية من صحة StreamService.
class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  Timer? _heartbeat;
  bool running = false;
  bool _heartbeatInFlight = false;

  void start() {
    if (running) return;
    running = true;

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 20),
      (_) => heartbeat(),
    );

    unawaited(heartbeat());
    debugPrint('[AgentService] started, heartbeat every 20s');
  }

  Future<void> heartbeat() async {
    if (!running || _heartbeatInFlight) return;
    _heartbeatInFlight = true;

    try {
      // ✅ اجعل StreamService يتحقق من حالة WS بنفسه
      await StreamService.instance.ensureHealthy();
    } catch (e) {
      debugPrint('[AgentService] heartbeat error: $e');
    } finally {
      _heartbeatInFlight = false;
    }
  }

  void stop() {
    running = false;
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}
