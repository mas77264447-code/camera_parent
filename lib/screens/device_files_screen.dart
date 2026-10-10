import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/camera_service.dart';

class DeviceFilesScreen extends StatefulWidget {
  final String sessionId;
  final String name;
  final String adminToken;

  const DeviceFilesScreen({
    super.key,
    required this.sessionId,
    required this.name,
    required this.adminToken,
  });

  @override
  State<DeviceFilesScreen> createState() => _DeviceFilesScreenState();
}

class _DeviceFilesScreenState extends State<DeviceFilesScreen>
    with SingleTickerProviderStateMixin {
  static const _manageChannel =
      MethodChannel('camera_parent/manage_storage');

  late TabController _tabs;

  WebSocket? _ws;
  bool _approved = false;
  bool _ready = false;
  String _status = "جاري الاتصال...";

  List<Map<String, dynamic>> _galleryItems = [];
  List<Map<String, dynamic>> _fileItems = [];
  String? _currentPath;
  String? _parentPath;
  bool _loading = false;
  Timer? _loadTimeout;

  final Map<String, _DownloadState> _downloads = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    _connect();
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    _tabs.dispose();
    try {
      if (_ws?.readyState == WebSocket.open) {
        _ws!.add(jsonEncode({'type': 'leave-viewer'}));
      }
      _ws?.close();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      final wsUrl = CameraService.server
              .replaceFirst('https://', 'wss://')
              .replaceFirst('http://', 'ws://') +
          '/signal';

      _ws = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 10));

      _ws!.add(jsonEncode({
        'type': 'register',
        'role': 'viewer',
        'session': widget.sessionId,
        'adminToken': widget.adminToken,
        'name': 'الوالد',
        'requestedSource': 'files',
      }));

      _ws!.listen(
        _handleMessage,
        onError: (e) {
          if (mounted) setState(() => _status = 'خطأ في الاتصال');
        },
        onDone: () {
          if (mounted) setState(() => _status = 'انقطع الاتصال');
        },
        cancelOnError: true,
      );

      setState(() => _status = 'جاري التحقق من الجهاز...');
    } catch (e) {
      if (mounted) setState(() => _status = 'فشل الاتصال: $e');
    }
  }

  void _handleMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      final type = msg['type'] as String?;

      switch (type) {
        case 'viewer-approved':
          setState(() {
            _approved = true;
            _ready = true;
            _status = 'متصل — اختر صور / فيديو / ملفات';
          });
          break;

        case 'await-approval':
          setState(() => _status = 'في انتظار موافقة جهاز الطفل...');
          break;

        case 'join-rejected':
          setState(() {
            _status = 'جهاز الطفل رفض الاتصال';
            _ready = true;
          });
          break;

        case 'auth-failed':
          setState(() {
            _status = 'فشل التحقق من الجلسة';
            _ready = true;
          });
          break;

        case 'broadcaster-left':
          setState(() {
            _approved = false;
            _status = 'انقطع جهاز الطفل — في انتظار عودته...';
          });
          break;

        case 'file-browser-list-response':
          _loadTimeout?.cancel();
          final ok = msg['ok'] == true;
          final items = (msg['items'] as List?)
                  ?.map((e) => Map<String, dynamic>.from(e as Map))
                  .toList() ??
              [];
          final path = msg['path']?.toString();
          final errorMsg = msg['error']?.toString();

          setState(() {
            _loading = false;
            if (!ok) {
              _status = 'خطأ: ${errorMsg ?? 'unknown'}';
              return;
            }
            if (path != null && path.startsWith('gallery://')) {
              _galleryItems = items;
              _status = '${items.length} عنصر';
            } else {
              _fileItems = items;
              _currentPath = path;
              _parentPath = msg['parent']?.toString();
              _status = errorMsg != null && errorMsg.isNotEmpty
                  ? 'تنبيه: $errorMsg'
                  : '${items.length} عنصر';
            }
          });
          break;

        case 'file-transfer-start':
          final requestId = msg['requestId']?.toString();
          if (requestId == null) return;
          setState(() {
            _downloads[requestId] = _DownloadState(
              name: msg['name']?.toString() ?? 'file',
              size: (msg['size'] as num?)?.toInt() ?? 0,
              received: 0,
              chunks: [],
            );
          });
          break;

        case 'file-transfer-chunk':
          final requestId = msg['requestId']?.toString();
          final data = msg['data'] as String?;
          if (requestId == null || data == null) return;
          final state = _downloads[requestId];
          if (state == null) return;
          try {
            final bytes = base64Decode(data);
            state.chunks.add(bytes);
            state.received += bytes.length;
            setState(() {});
          } catch (_) {}
          break;

        case 'file-transfer-end':
          final requestId = msg['requestId']?.toString();
          if (requestId == null) return;
          _finishDownload(requestId);
          break;
      }
    } catch (e) {
      debugPrint('[Files] msg error: $e');
    }
  }

  // ✅ فتح إعدادات "الوصول لجميع الملفات"
  Future<void> _requestFullAccess() async {
    try {
      await _manageChannel.invokeMethod('openSettings');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('فعّل "الوصول لجميع الملفات" ثم ارجع للتطبيق'),
          duration: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر فتح الإعدادات: $e')),
      );
    }
  }

  // ✅ التحقق من صلاحية MANAGE
  Future<bool> _hasFullAccess() async {
    try {
      return await _manageChannel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadRoot() async {
    if (_ws?.readyState != WebSocket.open || !_approved) return;

    // ✅ إذا لم تكن صلاحية MANAGE موجودة — افتح الإعدادات
    final has = await _hasFullAccess();
    if (!has) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('صلاحية مطلوبة'),
          content: const Text(
            'لتصفح كل ملفات الجهاز، نحتاج صلاحية "الوصول لجميع الملفات".\n\n'
            'ستفتح الآن شاشة إعدادات. فعّل الخيار ثم ارجع.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لاحقاً'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('فتح الإعدادات'),
            ),
          ],
        ),
      );
      if (go == true) {
        await _requestFullAccess();
      }
      return;
    }

    _startLoadTimeout('جاري قراءة الملفات...');
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': _uid(),
      'uri': null,
    }));
  }

  void _openPath(String path) {
    if (_ws?.readyState != WebSocket.open || !_approved) return;
    _startLoadTimeout('جاري قراءة المجلد...');
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': _uid(),
      'uri': path,
    }));
  }

  void _loadGallery(String type) {
    if (_ws?.readyState != WebSocket.open || !_approved) {
      setState(() => _status = 'الجهاز غير جاهز — أعد المحاولة');
      return;
    }
    _startLoadTimeout(
        'جاري تحميل ${type == 'image' ? 'الصور' : 'الفيديو'}...');
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': _uid(),
      'uri': 'gallery://$type',
    }));
  }

  void _startLoadTimeout(String statusText) {
    _loadTimeout?.cancel();
    setState(() {
      _loading = true;
      _status = statusText;
    });
    _loadTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _status = 'انتهت المهلة — الجهاز لم يستجب';
        });
      }
    });
  }

  void _download(String uri, String name) {
    if (_ws?.readyState != WebSocket.open || !_approved) return;
    final requestId = _uid();
    setState(() {
      _downloads[requestId] = _DownloadState(
        name: name,
        size: 0,
        received: 0,
        chunks: [],
      );
    });
    _ws!.add(jsonEncode({
      'type': 'file-browser-download',
      'requestId': requestId,
      'uri': uri,
      'name': name,
    }));
  }

  Future<void> _finishDownload(String requestId) async {
    final state = _downloads[requestId];
    if (state == null) return;

    try {
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final safeName = state.name.replaceAll(RegExp(r'[^\w\.\-]'), '_');
      final file = File('${dir.path}/$safeName');

      final builder = BytesBuilder();
      for (final c in state.chunks) {
        builder.add(c);
      }
      await file.writeAsBytes(builder.toBytes());

      if (!mounted) return;
      setState(() => _downloads.remove(requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تم الحفظ: ${file.path}'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloads.remove(requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الحفظ: $e')),
      );
    }
  }

  static String _uid() =>
      DateTime.now().microsecondsSinceEpoch.toString() +
      '_' +
      (1000 + (DateTime.now().millisecond % 9000)).toString();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'الصور والفيديو', icon: Icon(Icons.photo_library)),
            Tab(text: 'الملفات', icon: Icon(Icons.folder)),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: _approved
                ? Colors.green.shade100
                : (_ready ? Colors.red.shade100 : Colors.orange.shade100),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
          if (_downloads.isNotEmpty) _buildDownloadBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildGalleryTab(),
                _buildFilesTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadBanner() {
    final entries = _downloads.entries.toList();
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.blue.shade50,
      child: Column(
        children: entries.map((e) {
          final state = e.value;
          final pct = state.size > 0
              ? (state.received / state.size).clamp(0.0, 1.0)
              : null;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.download, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.name,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: pct),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(state.received / 1024).toStringAsFixed(0)} KB',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGalleryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _approved ? () => _loadGallery('image') : null,
                  icon: const Icon(Icons.photo),
                  label: const Text('الصور'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _approved ? () => _loadGallery('video') : null,
                  icon: const Icon(Icons.videocam),
                  label: const Text('الفيديو'),
                ),
              ),
            ],
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(),
          )
        else if (_galleryItems.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'اختر "الصور" أو "الفيديو"\nلبحث المعرض',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ),
          )
        else
          Expanded(child: _buildItemsList(_galleryItems)),
      ],
    );
  }

  Widget _buildFilesTab() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Colors.grey.shade200,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home),
                tooltip: 'الرئيسي',
                onPressed: _approved ? _loadRoot : null,
              ),
              if (_parentPath != null &&
                  _parentPath!.isNotEmpty &&
                  _parentPath != '/')
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'أعلى',
                  onPressed: () => _openPath(_parentPath!),
                ),
              Expanded(
                child: Text(
                  _currentPath ?? 'الرئيسي',
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
        // ✅ زر "تفعيل الوصول الكامل للملفات"
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton.icon(
            onPressed: _requestFullAccess,
            icon: const Icon(Icons.settings, size: 18),
            label: const Text('تفعيل الوصول لجميع الملفات'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.deepPurple,
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(),
          )
        else if (_fileItems.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_open, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text(
                    'اضغط "بدء الاستعراض" لتصفح كل ملفات الجهاز',
                    style: TextStyle(color: Colors.black54),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _approved ? _loadRoot : null,
                    child: const Text('بدء الاستعراض'),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(child: _buildItemsList(_fileItems)),
      ],
    );
  }

  Widget _buildItemsList(List<Map<String, dynamic>> items) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final name = item['name']?.toString() ?? 'file';
        final uri = item['uri']?.toString() ?? '';
        final isDir = item['isDirectory'] == true;
        final size = (item['size'] as num?)?.toInt() ?? 0;
        final mime = item['mime']?.toString() ?? '';

        return ListTile(
          leading: Icon(
            isDir
                ? Icons.folder
                : (mime.startsWith('image/')
                    ? Icons.image
                    : mime.startsWith('video/')
                        ? Icons.videocam
                        : mime.startsWith('audio/')
                            ? Icons.audiotrack
                            : Icons.insert_drive_file),
            color: isDir ? Colors.amber.shade700 : Colors.blue,
          ),
          title: Text(name, overflow: TextOverflow.ellipsis),
          subtitle: Text(isDir ? 'مجلد' : _humanSize(size)),
          trailing: isDir
              ? const Icon(Icons.chevron_right)
              : IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () => _download(uri, name),
                ),
          onTap: isDir ? () => _openPath(uri) : null,
        );
      },
    );
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}

class _DownloadState {
  final String name;
  final int size;
  int received;
  final List<Uint8List> chunks;

  _DownloadState({
    required this.name,
    required this.size,
    required this.received,
    required this.chunks,
  });
}