import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Singleton يحتفظ باتصال WebSocket خارج دورة حياة الشاشة.
/// بهذه الطريقة، الاتصال يستمر حتى بعد إغلاق الواجهة.
class WsHolder {
  WsHolder._();
  static final WsHolder instance = WsHolder._();

  WebSocket? _ws;
  bool _connecting = false;

  final _messageController = StreamController<dynamic>.broadcast();
  Stream<dynamic> get messages => _messageController.stream;

  bool get isConnected => _ws != null && _ws!.readyState == WebSocket.open;

  /// اتصال (إذا لم يكن متصلاً بالفعل)
  Future<bool> connect(String url) async {
    if (isConnected) {
      debugPrint('[WsHolder] already connected');
      return true;
    }
    if (_connecting) {
      debugPrint('[WsHolder] connect already in progress');
      return false;
    }
    _connecting = true;

    try {
      debugPrint('[WsHolder] connecting to $url');
      final ws = await WebSocket.connect(url)
          .timeout(const Duration(seconds: 15));

      _ws = ws;
      ws.listen(
        (data) {
          _messageController.add(data);
        },
        onError: (e) {
          debugPrint('[WsHolder] error: $e');
          _messageController.addError(e);
          _ws = null;
        },
        onDone: () {
          debugPrint('[WsHolder] connection done');
          _ws = null;
        },
        cancelOnError: false,
      );

      debugPrint('[WsHolder] connected ✅');
      return true;
    } catch (e) {
      debugPrint('[WsHolder] connect failed: $e');
      _ws = null;
      return false;
    } finally {
      _connecting = false;
    }
  }

  /// إرسال رسالة JSON
  void send(Map<String, dynamic> data) {
    if (!isConnected) {
      debugPrint('[WsHolder] send skipped — not connected');
      return;
    }
    try {
      _ws!.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[WsHolder] send error: $e');
    }
  }

  /// إغلاق الاتصال (يُستخدم فقط عند إلغاء الاقتران)
  void disconnect() {
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
  }

  /// للاستخدام الداخلي — الحصول على ws.readyState
  WebSocket? get raw => _ws;
}
