import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../services/camera_service.dart';
import '../services/device_file_access_service.dart';

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

class _DeviceFilesScreenState extends State<DeviceFilesScreen> {
  WebSocket? _ws;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _rejected = false;
  bool _ready = false;
  String _status = 'جاري الاتصال بجهاز Camera...';
  String? _currentUri;
  final List<_FolderEntry> _entries = [];
  final List<_FolderLocation> _history = [];
  final Map<String, _IncomingTransfer> _transfers = {};
  final Set<String> _loadingRequests = {};

  static const int _maxIncomingBytes = 25 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    try {
      if (_ws?.readyState == WebSocket.open) {
        _ws!.add(jsonEncode({'type': 'leave-viewer'}));
      }
    } catch (_) {}
    try { _ws?.close(); } catch (_) {}
    super.dispose();
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';

  Future<void> _connect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    try {
      final wsUrl = CameraService.server.replaceFirst(RegExp(r'^http'), 'ws');
      final socket = await WebSocket.connect('$wsUrl/signal').timeout(const Duration(seconds: 10));
      if (_disposed) {
        socket.close();
        return;
      }
      _ws = socket;
      socket.add(jsonEncode({
        'type': 'register',
        'role': 'viewer',
        'session': widget.sessionId,
        'adminToken': widget.adminToken,
        'name': widget.name,
        'requestedSource': 'files',
      }));
      setState(() => _status = 'في انتظار موافقة صاحب الجهاز...');
      socket.listen(_onMessage, onDone: _onDone, onError: (_) => _onDone());
    } catch (_) {
      if (mounted) setState(() => _status = 'تعذر الاتصال — إعادة المحاولة...');
      _scheduleReconnect();
    }
  }

  void _onDone() {
    if (_disposed || _rejected) return;
    if (mounted) setState(() => _status = 'انقطع الاتصال — إعادة المحاولة...');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _rejected || _reconnectTimer != null) return;
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _reconnectTimer = null;
      _connect();
    });
  }

  Future<void> _onMessage(dynamic raw) async {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'await-approval':
          if (mounted) setState(() => _status = 'في انتظار موافقة صاحب الجهاز...');
          break;
        case 'join-rejected':
          _rejected = true;
          if (mounted) setState(() => _status = 'تم رفض طلب الوصول إلى الملفات');
          break;
        case 'file-browser-ready':
          _ready = msg['granted'] == true;
          if (!_ready) {
            if (mounted) setState(() => _status = msg['error']?.toString() ?? 'لم تتم الموافقة');
            break;
          }
          if (mounted) setState(() => _status = 'تمت الموافقة — جاري قراءة الملفات...');
          await _listFolder(null);
          break;
        case 'file-browser-list-response':
          final requestId = msg['requestId']?.toString();
          if (requestId != null) _loadingRequests.remove(requestId);
          if (msg['ok'] != true) {
            if (mounted) setState(() => _status = msg['error']?.toString() ?? 'تعذر قراءة المجلد');
            break;
          }
          final list = (msg['items'] as List? ?? const [])
              .map((e) => _FolderEntry.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          if (mounted) {
            setState(() {
              _entries
                ..clear()
                ..addAll(list);
              _status = '${list.length} عنصر';
            });
          }
          break;
        case 'file-transfer-start':
          _startTransfer(msg);
          break;
        case 'file-transfer-chunk':
          _appendTransfer(msg);
          break;
        case 'file-transfer-end':
          await _finishTransfer(msg);
          break;
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'خطأ في بيانات الملفات');
    }
  }

  Future<void> _listFolder(String? uri) async {
    if (!_ready || _ws?.readyState != WebSocket.open) return;
    final requestId = _newId();
    _loadingRequests.add(requestId);
    _ws!.add(jsonEncode({
      'type': 'file-browser-list',
      'requestId': requestId,
      'uri': uri,
    }));
    if (mounted) setState(() => _status = 'جاري تحميل المجلد...');
  }

  Future<void> _openFolder(_FolderEntry entry) async {
    if (!entry.isDirectory) return;
    _history.add(_FolderLocation(uri: _currentUri, title: _currentTitle));
    _currentUri = entry.uri;
    await _listFolder(entry.uri);
  }

  String get _currentTitle => _history.isEmpty ? 'ملفات الجهاز' : (_history.last.title);

  Future<void> _goBackFolder() async {
    if (_history.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final previous = _history.removeLast();
    _currentUri = previous.uri;
    await _listFolder(_currentUri);
  }

  void _download(_FolderEntry entry) {
    if (!_ready || entry.isDirectory || _ws?.readyState != WebSocket.open) return;
    if (entry.size > _maxIncomingBytes) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الملف أكبر من 25 ميجابايت')));
      return;
    }
    final requestId = _newId();
    _ws!.add(jsonEncode({
      'type': 'file-browser-download',
      'requestId': requestId,
      'uri': entry.uri,
      'name': entry.name,
    }));
    setState(() => _status = 'جاري استلام ${entry.name}...');
  }

  void _startTransfer(Map<String, dynamic> msg) {
    final id = msg['requestId']?.toString();
    final size = (msg['size'] as num?)?.toInt() ?? 0;
    if (id == null || size < 0 || size > _maxIncomingBytes) return;
    _transfers[id] = _IncomingTransfer(
      name: msg['name']?.toString() ?? 'file',
      size: size,
      chunks: [],
    );
  }

  void _appendTransfer(Map<String, dynamic> msg) {
    final id = msg['requestId']?.toString();
    final data = msg['data']?.toString();
    final transfer = id == null ? null : _transfers[id];
    if (transfer == null || data == null) return;
    try {
      final bytes = base64Decode(data);
      final received = transfer.chunks.fold<int>(0, (s, c) => s + c.length);
      if (received + bytes.length > _maxIncomingBytes || received + bytes.length > transfer.size) {
        _transfers.remove(id);
        return;
      }
      transfer.chunks.add(bytes);
    } catch (_) {}
  }

  Future<void> _finishTransfer(Map<String, dynamic> msg) async {
    final id = msg['requestId']?.toString();
    if (id == null) return;
    final transfer = _transfers.remove(id);
    if (transfer == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safe = transfer.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${dir.path}/received_${DateTime.now().millisecondsSinceEpoch}_$safe');
      final sink = file.openWrite();
      for (final chunk in transfer.chunks) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      if (mounted) {
        setState(() => _status = 'تم حفظ ${transfer.name} ✓');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم حفظ ${transfer.name} داخل ملفات التطبيق')));
      }
    } catch (_) {
      if (mounted) setState(() => _status = 'تعذر حفظ الملف');
    }
  }

  IconData _iconFor(_FolderEntry e) {
    if (e.isDirectory) return Icons.folder;
    final mime = e.mime.toLowerCase();
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.startsWith('video/')) return Icons.video_file;
    if (mime.startsWith('audio/')) return Icons.audio_file;
    if (mime.contains('pdf')) return Icons.picture_as_pdf;
    if (mime.contains('text')) return Icons.description;
    return Icons.insert_drive_file;
  }

  String _sizeText(int size) {
    if (size < 0) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _goBackFolder,
        ),
        title: Text(widget.name.isEmpty ? 'ملفات الجهاز' : 'ملفات ${widget.name}'),
        actions: [
          if (_ready)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _listFolder(_currentUri),
              tooltip: 'تحديث',
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(_status, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Expanded(
            child: !_ready
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? const Center(child: Text('المجلد فارغ'))
                    : ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          return ListTile(
                            leading: Icon(_iconFor(e)),
                            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(e.isDirectory ? 'مجلد' : '${e.mime}  ${_sizeText(e.size)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: e.isDirectory
                                ? const Icon(Icons.chevron_left)
                                : IconButton(
                                    icon: const Icon(Icons.download_outlined),
                                    tooltip: 'استلام الملف',
                                    onPressed: () => _download(e),
                                  ),
                            onTap: e.isDirectory ? () => _openFolder(e) : () => _download(e),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _FolderEntry {
  final String uri;
  final String name;
  final String mime;
  final int size;
  final bool isDirectory;

  const _FolderEntry({
    required this.uri,
    required this.name,
    required this.mime,
    required this.size,
    required this.isDirectory,
  });

  factory _FolderEntry.fromJson(Map<String, dynamic> json) => _FolderEntry(
        uri: json['uri']?.toString() ?? '',
        name: json['name']?.toString() ?? 'بدون اسم',
        mime: json['mime']?.toString() ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? -1,
        isDirectory: json['isDirectory'] == true,
      );
}

class _FolderLocation {
  final String? uri;
  final String title;
  const _FolderLocation({required this.uri, required this.title});
}

class _IncomingTransfer {
  final String name;
  final int size;
  final List<List<int>> chunks;
  _IncomingTransfer({required this.name, required this.size, required this.chunks});
}
