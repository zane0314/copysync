import 'dart:convert';
import 'dart:io';

/// multipart 表单的一个字段（name 必有；文件字段带 filename/contentType/bytes）。
class FakePart {
  FakePart({required this.name, this.filename, this.contentType, this.bytes});

  final String name;
  final String? filename;
  final String? contentType;
  final List<int>? bytes;

  String get text => utf8.decode(bytes ?? const []);
}

/// 用 dart:io HttpServer 模拟 v1 服务端契约（见 app.py route_v1）。
/// 支持：login、devices、sync（游标/墓碑）、items 创建（JSON 文本与
/// multipart 文件/图片双变体）/详情/内容下载、幂等键、
/// 故障注入（forceItemStatus/forceItemCode）、登录延迟（loginDelay）、
/// 增量游标拒绝（rejectIncrementalSync，用于 full_sync_required 回退测试）。
class FakeV1Server {
  HttpServer? _server;
  final Map<String, Map<String, Object?>> _idempotent = {};
  final Map<String, Map<String, Object?>> itemsById = {};
  final Map<String, Map<String, List<int>>> blobsById = {};
  final Map<String, Map<String, Object?>> deliveriesById = {};
  final List<Map<String, Object?>> _changes = [];
  final List<Map<String, String>> devices = [];
  int _seq = 0;
  int _itemSeq = 0;
  int _deliverySeq = 0;
  final List<HttpRequest> received = [];

  /// 与 received 对齐的原始请求体字节（multipart 断言用）。
  final List<List<int>> receivedBodies = [];

  /// 最后一次 multipart 请求解析出的字段（name -> FakePart）。
  Map<String, FakePart> lastMultipart = {};

  String password = 'dev-pw-123';
  Duration loginDelay = Duration.zero;

  /// POST /api/v1/items 的响应延迟（loading 态防重测试用）。
  Duration itemDelay = Duration.zero;

  /// 非 null 时，POST /api/v1/items 一律以该状态码失败。
  int? forceItemStatus;

  /// forceItemStatus 失败时使用的错误信封 code/message。
  String forceItemCode = 'server_error';
  String forceItemMessage = '服务器开小差了';

  /// true 时，cursor>0 的 sync 返回 409 full_sync_required。
  bool rejectIncrementalSync = false;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleSafely);
    return 'http://127.0.0.1:${_server!.port}';
  }

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  /// 测试结束 tearDown 强制关服务器时，进行中的请求会连接断开；
  /// 吞掉这类噪音避免未捕获异步错误使测试失败。
  Future<void> _handleSafely(HttpRequest req) async {
    try {
      await _handle(req);
    } on Object {
      // 连接被对端重置/关闭：仅测试收尾时出现，忽略。
    }
  }

  Future<void> stop() => _server!.close(force: true);

  int get requestCount => received.length;

  void recordChange(String entity, String entityId, String op) {
    _seq += 1;
    _changes.add({
      'seq': _seq,
      'entity': entity,
      'entity_id': entityId,
      'op': op,
      'created_at': '2026-08-25T00:00:00Z',
    });
  }

  String _tokenOf(HttpRequest req) =>
      req.headers.value('authorization')?.replaceFirst('Bearer ', '') ?? '';

  void _json(HttpResponse res, Object? body,
      {int status = 200, Map<String, String>? headers}) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    headers?.forEach(res.headers.set);
    res.write(jsonEncode(body));
    res.close();
  }

  void _fail(HttpResponse res, int status, String code, String message) {
    _json(res, {
      'error': {'code': code, 'message': message}
    }, status: status);
  }

  Map<String, Object?> _newItem(String text, String? targetDevice) {
    _itemSeq += 1;
    return {
      'id': 'item-$_itemSeq',
      'kind': 'text',
      'name': '文本',
      'mime': 'text/plain; charset=utf-8',
      'size': utf8.encode(text).length,
      'text': text,
      'note': '',
      'pinned': 0,
      'created_at': 1,
      'expires_at': 2,
      'source_device': 'dev-1',
      'target_device': targetDevice ?? 'all',
    };
  }

  String _guessMime(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    const mimes = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'txt': 'text/plain',
      'pdf': 'application/pdf',
    };
    return mimes[ext] ?? 'application/octet-stream';
  }

  /// 极简 multipart 解析：按 boundary 切分，提取 name/filename/内容字节。
  Map<String, FakePart> _parseMultipart(List<int> body, String boundary) {
    final parts = <String, FakePart>{};
    final delimiter = utf8.encode('--$boundary');
    final segments = _splitOn(body, delimiter);
    for (final segment in segments) {
      if (segment.length < 4) continue; // 开头空段与结尾 "--\r\n"
      final headerEnd = _indexOfCrlfCrlf(segment);
      if (headerEnd < 0) continue;
      // multipart 头部为 ASCII + UTF-8 文件名；内容字节按偏移切分不受影响。
      final headerText = utf8.decode(segment.sublist(0, headerEnd), allowMalformed: true);
      final disposition = RegExp(r'content-disposition:\s*form-data;\s*([^\r\n]+)',
              caseSensitive: false)
          .firstMatch(headerText)
          ?.group(1);
      if (disposition == null) continue;
      final name =
          RegExp(r'name="([^"]*)"').firstMatch(disposition)?.group(1);
      if (name == null) continue;
      final filename =
          RegExp(r'filename="([^"]*)"').firstMatch(disposition)?.group(1);
      final contentType = RegExp(r'content-type:\s*([^\r\n]+)',
              caseSensitive: false)
          .firstMatch(headerText)
          ?.group(1)
          ?.trim();
      var content = segment.sublist(headerEnd + 4);
      if (content.length >= 2 &&
          content[content.length - 2] == 13 &&
          content[content.length - 1] == 10) {
        content = content.sublist(0, content.length - 2); // 去掉结尾 \r\n
      }
      parts[name] = FakePart(
        name: name,
        filename: filename,
        contentType: contentType,
        bytes: content,
      );
    }
    return parts;
  }

  List<List<int>> _splitOn(List<int> data, List<int> delimiter) {
    final result = <List<int>>[];
    var start = 0;
    outer:
    for (var i = 0; i + delimiter.length <= data.length; i++) {
      for (var j = 0; j < delimiter.length; j++) {
        if (data[i + j] != delimiter[j]) continue outer;
      }
      result.add(data.sublist(start, i));
      start = i + delimiter.length;
      i = start - 1;
    }
    result.add(data.sublist(start));
    return result;
  }

  int _indexOfCrlfCrlf(List<int> data) {
    for (var i = 0; i + 4 <= data.length; i++) {
      if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  Future<void> _handle(HttpRequest req) async {
    received.add(req);
    final bodyBytes = await req.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    receivedBodies.add(bodyBytes);
    final contentType = req.headers.contentType;
    final isMultipart = contentType?.mimeType == 'multipart/form-data';
    Map<String, Object?> body = {};
    if (isMultipart) {
      lastMultipart =
          _parseMultipart(bodyBytes, contentType!.parameters['boundary'] ?? '');
    } else if (bodyBytes.isNotEmpty) {
      body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, Object?>;
    }
    final path = req.uri.path;
    if (path == '/api/v1/auth/login') {
      if (loginDelay > Duration.zero) await Future<void>.delayed(loginDelay);
      if (body['password'] != password) {
        return _fail(req.response, 401, 'invalid_credentials', '密码错误');
      }
      final device = {
        'id': 'dev-1',
        'name': body['device_name'],
        'platform': body['platform'],
      };
      devices.add({
        'id': 'dev-1',
        'name': '${body['device_name']}',
        'platform': '${body['platform']}',
      });
      recordChange('device', 'dev-1', 'upsert');
      return _json(req.response, {'token': 'cps_tok_1', 'device': device});
    }
    if (_tokenOf(req) != 'cps_tok_1') {
      return _fail(req.response, 401, 'unauthorized', '未认证');
    }
    if (path == '/api/v1/devices') {
      return _json(req.response, {
        'devices': devices
            .map((d) => {...d, 'last_seen_at': 0, 'online': true})
            .toList(),
      });
    }
    if (path == '/api/v1/sync') {
      final cursor =
          int.tryParse(req.uri.queryParameters['cursor'] ?? '') ?? -1;
      if (cursor < 0) {
        return _fail(req.response, 409, 'full_sync_required', '游标无效');
      }
      if (cursor > 0 && rejectIncrementalSync) {
        return _fail(
            req.response, 409, 'full_sync_required', '游标早于保留窗口');
      }
      final changes =
          _changes.where((c) => (c['seq'] as int) > cursor).toList();
      final tombstones = changes
          .where((c) => c['op'] == 'delete')
          .map((c) => {'entity': c['entity'], 'entity_id': c['entity_id']})
          .toList();
      return _json(req.response, {
        'changes': changes,
        'tombstones': tombstones,
        'next_cursor': changes.isEmpty ? cursor : changes.last['seq'],
      });
    }
    if (path == '/api/v1/items' && req.method == 'POST') {
      if (itemDelay > Duration.zero) await Future<void>.delayed(itemDelay);
      if (forceItemStatus != null) {
        return _fail(
            req.response, forceItemStatus!, forceItemCode, forceItemMessage);
      }
      final key = req.headers.value('idempotency-key') ?? '';
      if (key.isNotEmpty && _idempotent.containsKey(key)) {
        return _json(req.response, _idempotent[key]!,
            headers: {'X-Idempotent-Replay': '1'});
      }
      final Map<String, Object?> item;
      if (isMultipart) {
        final file = lastMultipart['file'];
        if (file == null || file.filename == null) {
          return _fail(req.response, 400, 'no_file', '缺少文件字段 file');
        }
        item = _newFileItem(file, lastMultipart);
        blobsById[item['id'] as String] = {
          'original': file.bytes!,
          if (lastMultipart['clipboard_variant']?.bytes != null)
            'clipboard': lastMultipart['clipboard_variant']!.bytes!,
        };
      } else {
        item = _newItem('${body['text']}', body['target_device'] as String?);
      }
      itemsById[item['id'] as String] = item;
      recordChange('item', item['id'] as String, 'upsert');
      final result = {'item': item};
      if (key.isNotEmpty) _idempotent[key] = result;
      return _json(req.response, result);
    }
    final contentMatch =
        RegExp(r'^/api/v1/items/([^/]+)/content$').firstMatch(path);
    if (contentMatch != null && req.method == 'GET') {
      final id = contentMatch.group(1)!;
      final variant = req.uri.queryParameters['variant'] ?? 'original';
      final item = itemsById[id];
      if (item == null) {
        return _fail(req.response, 404, 'item_not_found', '项目不存在');
      }
      final blob = blobsById[id]?[variant];
      if (blob == null) {
        return _fail(req.response, 404, 'variant_missing', '该变体不存在');
      }
      req.response.statusCode = 200;
      req.response.headers.contentType =
          ContentType.parse('${item['mime']}');
      req.response.add(blob);
      return req.response.close();
    }
    final itemMatch = RegExp(r'^/api/v1/items/([^/]+)$').firstMatch(path);
    if (itemMatch != null && req.method == 'GET') {
      final item = itemsById[itemMatch.group(1)];
      if (item == null) return _fail(req.response, 404, 'not_found', '项目不存在');
      return _json(req.response, {'item': item});
    }
    if (itemMatch != null && req.method == 'PATCH') {
      final item = itemsById[itemMatch.group(1)];
      if (item == null) {
        return _fail(req.response, 404, 'item_not_found', '项目不存在');
      }
      if (body.containsKey('pinned')) {
        item['pinned'] = body['pinned'] == true ? 1 : 0;
        item['expires_at'] = body['pinned'] == true ? null : 2;
      }
      if (body.containsKey('note')) item['note'] = body['note'];
      if (body.containsKey('ttl')) {
        item['expires_at'] = 1000000 + (body['ttl'] as num).toInt();
      }
      recordChange('item', item['id'] as String, 'upsert');
      return _json(req.response, {'item': item});
    }
    if (itemMatch != null && req.method == 'DELETE') {
      final id = itemMatch.group(1)!;
      if (!itemsById.containsKey(id)) {
        return _fail(req.response, 404, 'item_not_found', '项目不存在');
      }
      itemsById.remove(id);
      blobsById.remove(id);
      recordChange('item', id, 'delete');
      return _json(req.response, {'ok': true, 'id': id});
    }
    final deliveriesMatch =
        RegExp(r'^/api/v1/items/([^/]+)/deliveries$').firstMatch(path);
    if (deliveriesMatch != null && req.method == 'POST') {
      final item = itemsById[deliveriesMatch.group(1)];
      if (item == null) {
        return _fail(req.response, 404, 'item_not_found', '项目不存在');
      }
      final target = '${body['target_device'] ?? ''}';
      if (target.isEmpty) {
        return _fail(req.response, 400, 'bad_request', '缺少 target_device');
      }
      // 登录设备固定为 dev-1；其余目标必须出现在设备列表。
      if (target != 'dev-1' && !devices.any((d) => d['id'] == target)) {
        return _fail(req.response, 404, 'device_not_found', '目标设备不存在');
      }
      _deliverySeq += 1;
      final now = 1000000 + _deliverySeq;
      final delivery = <String, Object?>{
        'id': 'dlv-$_deliverySeq',
        'item_id': item['id'],
        'source_device': 'dev-1',
        'target_device': target,
        'status': target == 'web' ? 'delivered' : 'waiting',
        'created_at': now,
        'updated_at': now,
      };
      deliveriesById[delivery['id'] as String] = delivery;
      recordChange('delivery', delivery['id'] as String, 'upsert');
      return _json(req.response, {'delivery': delivery});
    }
    final ackMatch =
        RegExp(r'^/api/v1/deliveries/([^/]+)/ack$').firstMatch(path);
    if (ackMatch != null && req.method == 'POST') {
      final delivery = deliveriesById[ackMatch.group(1)];
      if (delivery == null) {
        return _fail(req.response, 404, 'delivery_not_found', '投递不存在');
      }
      if (delivery['target_device'] != 'dev-1') {
        return _fail(req.response, 403, 'device_mismatch', '只能由目标设备确认');
      }
      final status = '${body['status'] ?? 'delivered'}';
      delivery['status'] = status;
      recordChange('delivery', delivery['id'] as String, 'upsert');
      return _json(req.response, {'delivery': delivery});
    }
    if (path == '/api/v1/usage' && req.method == 'GET') {
      return _json(req.response, {
        'temp_bytes': 2048,
        'pinned_bytes': 1024,
        'total_bytes': 3072,
        'limits': {'pinned': 1048576, 'temp': 2097152, 'max_file': 10485760},
      });
    }
    if (path == '/api/v1/auth/logout' && req.method == 'POST') {
      return _json(req.response, {'ok': true});
    }
    return _fail(req.response, 404, 'not_found', '接口不存在');
  }

  Map<String, Object?> _newFileItem(
      FakePart file, Map<String, FakePart> form) {
    _itemSeq += 1;
    final mime = _guessMime(file.filename!);
    return {
      'id': 'item-$_itemSeq',
      'kind': mime.startsWith('image/') ? 'image' : 'file',
      'name': file.filename,
      'mime': mime,
      'size': file.bytes!.length,
      'text': '',
      'note': form['note']?.text ?? '',
      'pinned': 0,
      'created_at': 1,
      'expires_at': 2,
      'source_device': 'dev-1',
      'target_device':
          form['target_device']?.text.isNotEmpty == true ? form['target_device']!.text : 'all',
    };
  }
}
