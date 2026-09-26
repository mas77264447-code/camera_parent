import 'dart:async';

import 'stream_service.dart';

/// فحص استقرار دوري (أبطأ من نبضة AgentService) فوق StreamService الحقيقي.
///
/// ✅ إصلاح: كان يعمل على StreamManager.instance الفارغ فلا يفعل شيئاً.
class StabilityController {
  StabilityController._();
  static final StabilityController instance = StabilityController._();

  Timer? _pollTimer;
  bool running = false;
  bool _inFlight = false;

  void start() {
    if (running) return;
    running = true;

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_check()),
    );
  }

  Future<void> _check() async {
    if (!running || _inFlight) return;
    _inFlight = true;
    try {
      await StreamService.instance.ensureHealthy();
    } catch (_) {
      // نتجاهل: الفحص القادم سيعيد المحاولة.
    } finally {
      _inFlight = false;
    }
  }

  void stop() {
    running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}
