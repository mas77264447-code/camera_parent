import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stream_service.dart';

/// Heartbeat: checks StreamService every 20s and restarts it from the
/// saved session if it is not running (e.g. after the process was killed).
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
      final svc = StreamService.instance;
      if (!svc.running) {
        final prefs = await SharedPreferences.getInstance();
        final paired = prefs.getBool('is_paired') ?? false;
        final token = prefs.getString('device_token');
        final session = prefs.getString('session_id');
        final name = prefs.getString('device_name') ?? 'Camera';
        if (paired && token != null && session != null) {
          debugPrint('[AgentService] stream not running - starting from saved session');
          await svc.start(
            sessionId: session,
            deviceToken: token,
            cameraName: name,
          );
          try {
            await svc.ensureCameraStarted();
          } catch (e) {
            debugPrint('[AgentService] camera start failed: $e');
          }
        }
      } else {
        await svc.ensureHealthy();
      }
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
