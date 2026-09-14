import 'package:flutter/services.dart';

/// خدمة التواصل مع صلاحيات Device Admin / Device Owner
/// --------------------------------------------------------
/// Device Admin  → يتفعّل بموافقة المستخدم (نافذة نظام)
/// Device Owner  → يتطلب ADB + Factory Reset (شوف ملف الشرح)
class DeviceAdminService {
  static const _channel = MethodChannel("camera_parent/device_admin");

  // ─── Device Admin ─────────────────────────────────────

  /// هل التطبيق مفعّل كـ Device Admin حاليًا؟
  static Future<bool> isAdminActive() async {
    try {
      return await _channel.invokeMethod("isAdminActive") ?? false;
    } catch (_) {
      return false;
    }
  }

  /// هل التطبيق مفعّل كـ Device Owner؟
  static Future<bool> isDeviceOwner() async {
    try {
      return await _channel.invokeMethod("isDeviceOwner") ?? false;
    } catch (_) {
      return false;
    }
  }

  /// افتح نافذة النظام اللي تطلب تفعيل Device Admin.
  /// بترجع: true (مفعّل بالفعل) | "requested" (فتح النافذة)
  static Future<dynamic> requestAdmin() async {
    try {
      return await _channel.invokeMethod("requestAdmin");
    } catch (_) {
      return false;
    }
  }

  /// اقفل شاشة الجهاز فورًا عن بعد (يتطلب Device Admin)
  static Future<bool> lockScreen() async {
    try {
      return await _channel.invokeMethod("lockScreen") ?? false;
    } on PlatformException catch (e) {
      if (e.code == "NOT_ADMIN") return false;
      rethrow;
    }
  }

  /// تفعيل/تعطيل كاميرا الجهاز كلها (يتطلب Device Admin)
  static Future<bool> setCameraDisabled(bool disabled) async {
    try {
      return await _channel.invokeMethod("setCameraDisabled", {"disabled": disabled}) ?? false;
    } on PlatformException catch (e) {
      if (e.code == "NOT_ADMIN") return false;
      rethrow;
    }
  }

  /// إلغاء Device Admin من داخل التطبيق
  static Future<void> removeAdmin() async {
    try {
      await _channel.invokeMethod("removeAdmin");
    } catch (_) {}
  }

  // ─── Kiosk / Lock Task ─────────────────────────────────

  /// حالة Kiosk الحالية. يدعم مسارين:
  /// 1) Device Owner = Lock Task مُدار بالكامل.
  /// 2) بدون Device Owner = Screen Pinning الرسمي من Android، بدون فورمات.
  static Future<Map<String, dynamic>> getKioskStatus() async {
    try {
      final value = await _channel.invokeMethod<dynamic>('getKioskStatus');
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
    } catch (_) {}
    return const <String, dynamic>{
      'supported': false,
      'deviceOwner': false,
      'lockTaskPermitted': false,
      'active': false,
      'enabled': false,
      'mode': 'unsupported',
    };
  }

  /// هل يمكن تشغيل Lock Task / Screen Pinning على هذا الجهاز؟
  static Future<bool> isKioskSupported() async {
    try {
      return await _channel.invokeMethod('isKioskSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// هل Lock Task أو Screen Pinning يعمل حاليًا؟
  static Future<bool> isKioskActive() async {
    try {
      return await _channel.invokeMethod('isKioskActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// هل تم طلب إبقاء الوضع مفعلاً؟
  static Future<bool> isKioskEnabled() async {
    try {
      return await _channel.invokeMethod('isKioskEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// تشغيل Kiosk المُدار إذا كان Device Owner، وإلا تشغيل Screen Pinning.
  static Future<bool> enableKioskMode() async {
    try {
      return await _channel.invokeMethod('enableKioskMode') ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'KIOSK_UNSUPPORTED' ||
          e.code == 'KIOSK_NOT_FOREGROUND' ||
          e.code == 'KIOSK_SECURITY') {
        return false;
      }
      rethrow;
    }
  }

  /// إيقاف Kiosk/Screen Pinning الذي بدأه التطبيق.
  static Future<bool> disableKioskMode() async {
    try {
      return await _channel.invokeMethod('disableKioskMode') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// منع المستخدم من تغيير إعدادات الواي فاي
  static Future<bool> disableWifiSettings() async {
    try {
      return await _channel.invokeMethod("disableWifiSettings") ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// منع تثبيت تطبيقات جديدة
  static Future<bool> disableInstallApps() async {
    try {
      return await _channel.invokeMethod("disableInstallApps") ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// منع Factory Reset من إعدادات الجهاز
  static Future<bool> disableFactoryReset() async {
    try {
      return await _channel.invokeMethod("disableFactoryReset") ?? false;
    } on PlatformException {
      return false;
    }
  }
}
