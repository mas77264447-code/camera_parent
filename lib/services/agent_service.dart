import 'dart:async';

import 'stream_service.dart';
import 'stability_controller.dart';

/// وكيل "دائم الاتصال" — يعمل كمراقب (watchdog) دوري فوق StreamService.
///
/// ✅ إصلاح: سابقاً كان يعمل على StreamManager.instance (سينغلتون منفصل لا
/// يُسجَّل فيه أي peerConnection أبداً)، فكانت نبضاته والاسترجاع بلا أثر على
/// الاتصالات الحقيقية. الآن يستدعي StreamService.ensureHealthy() مباشرة.
class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  Timer? _heartbeat;
  bool running = false;
  bool _inFlight = false;

  final StabilityController stability = StabilityController.instance;

  void start() {
    if (running) return;
    running = true;
    stability.start();

    _heartbeat?.cancel();
    // 20 ثانية: أقل من مهلة الخمول في السيرفر (35).
    _heartbeat = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _tick(),
    );

    unawaited(_tick());
  }

  Future<void> _tick() async {
    if (!running || _inFlight) return;
    _inFlight = true;
    try {
      await StreamService.instance.ensureHealthy();
    } catch (_) {
      // نتجاهل: المحاولة القادمة ستعيد الفحص.
    } finally {
      _inFlight = false;
    }
  }

  void stop() {
    running = false;
    stability.stop();
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}
