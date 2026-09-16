import 'dart:async';

import 'package:flutter/material.dart';
import '../services/connection_state_manager.dart';
import '../services/stream_manager.dart';
import '../services/recovery_state.dart';

class RecoveryDiagnosticsScreen extends StatefulWidget {
  const RecoveryDiagnosticsScreen({super.key});

  @override
  State<RecoveryDiagnosticsScreen> createState() =>
      _RecoveryDiagnosticsScreenState();
}

class _RecoveryDiagnosticsScreenState
    extends State<RecoveryDiagnosticsScreen> {
  StreamSubscription<ConnectionStatus>? _subscription;
  ConnectionStatus _status = ConnectionStateManager.instance.status;
  String? _detail = ConnectionStateManager.instance.detail;
  DateTime? _changedAt = ConnectionStateManager.instance.changedAt;
  StreamSubscription<RecoveryStateSnapshot>? _recoverySubscription;
  RecoveryStateSnapshot _recovery = RecoveryState.instance.snapshot;

  @override
  void initState() {
    super.initState();
    _recoverySubscription = RecoveryState.instance.changes.listen((snapshot) {
      if (!mounted) return;
      setState(() => _recovery = snapshot);
    });
    _subscription = ConnectionStateManager.instance.changes.listen((status) {
      if (!mounted) return;
      setState(() {
        _status = status;
        _detail = ConnectionStateManager.instance.detail;
        _changedAt = ConnectionStateManager.instance.changedAt;
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _recoverySubscription?.cancel();
    super.dispose();
  }

  String _label(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.idle:
        return 'Idle';
      case ConnectionStatus.connecting:
        return 'Connecting';
      case ConnectionStatus.connected:
        return 'Connected ✓';
      case ConnectionStatus.networkLost:
        return 'Network lost';
      case ConnectionStatus.reconnecting:
        return 'Reconnecting…';
      case ConnectionStatus.negotiating:
        return 'WebRTC negotiating…';
      case ConnectionStatus.failed:
        return 'Failed';
    }
  }

  String _pcSummary() {
    final pcs = StreamManager.instance.peerConnections;
    if (pcs.isEmpty) return 'لا توجد PeerConnections مسجلة';
    return pcs.entries.map((entry) {
      final state = entry.value.connectionState;
      return '${entry.key}: ${state?.name ?? 'unknown'}';
    }).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final manager = StreamManager.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('تشخيص Recovery')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Card(
            title: 'الحالة الحالية',
            child: Text(
              _label(_status),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
          _Card(
            title: 'التفاصيل',
            child: Text(_detail ?? '—'),
          ),
          _Card(
            title: 'آخر تغيير',
            child: Text(_changedAt?.toLocal().toString() ?? '—'),
          ),
          _Card(
            title: 'Signaling',
            child: Text(manager.isWebSocketConnected() ? 'Connected ✓' : 'Disconnected'),
          ),
          _Card(
            title: 'Media',
            child: Text(manager.running ? 'Running' : 'Stopped'),
          ),
          _Card(
            title: 'Recovery Engine',
            child: Text(
              'Phase: ${_recovery.phase.name}\nAttempts: ${_recovery.attempt}\nSuccesses: ${_recovery.successes}\nFailures: ${_recovery.failures}\n${_recovery.detail ?? ''}',
            ),
          ),
          _Card(
            title: 'PeerConnections',
            child: Text(_pcSummary()),
          ),
          const SizedBox(height: 12),
          const Text(
            'هذه الشاشة للتشخيص فقط. لا تغيّر صلاحيات Android ولا تحاول تجاوز موافقات النظام.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
