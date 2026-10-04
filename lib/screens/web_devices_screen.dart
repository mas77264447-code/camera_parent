import 'dart:async';
import 'package:flutter/material.dart';

class WebDevicesScreen extends StatefulWidget {
  final List<Map<String, dynamic>> Function() getDevices;
  final Future<void> Function() refresh;
  final void Function(Map<String, dynamic>) onOpen;
  final Future<void> Function(Map<String, dynamic>) onForget;

  const WebDevicesScreen({
    super.key,
    required this.getDevices,
    required this.refresh,
    required this.onOpen,
    required this.onForget,
  });

  @override
  State<WebDevicesScreen> createState() => _WebDevicesScreenState();
}

class _WebDevicesScreenState extends State<WebDevicesScreen> {
  Timer? _timer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await widget.refresh();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _confirmForget(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('حذف الجهاز'),
        content: Text('حذف "${d['name']}"؟ سيحتاج رابطاً جديداً للاتصال.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.onForget(d);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices =
        widget.getDevices().where((d) => d['source'] == 'web').toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('أجهزة الرابط'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: _loading && devices.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : devices.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'لا توجد أجهزة متصلة عبر رابط.\nأضف جهازاً من «إضافة عبر رابط».',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: devices.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = devices[i];
                    final online = d['online'] == true;
                    return ListTile(
                      leading: Icon(
                        Icons.circle,
                        size: 14,
                        color: online ? Colors.green : Colors.grey,
                      ),
                      title: Text('${d['name']}'),
                      subtitle: Text(online ? 'متصل الآن' : 'غير متصل'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmForget(d),
                      ),
                      onTap: online ? () => widget.onOpen(d) : null,
                    );
                  },
                ),
    );
  }
}
