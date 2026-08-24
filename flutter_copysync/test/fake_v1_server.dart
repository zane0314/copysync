import 'dart:convert';
import 'dart:io';

/// 用 dart:io HttpServer 模拟 v1 服务端契约（见 app.py route_v1）。
/// 支持：login、devices、sync（游标/墓碑）、items 创建/详情、幂等键、
/// 故障注入（forceItemStatus）、登录延迟（loginDelay）、增量游标拒绝
///（rejectIncrementalSync，用于 full_sync_required 回退测试）。
class FakeV1Server {
  HttpServer? _server;
  final Map<String, Map<String, Object?>> _idempotent = {};
  final Map<String, Map<String, Object?>> itemsById = {};
  final List<Map<String, Object?>> _changes = [];
  final List<Map<String, String>> devices = [];
  int _seq = 0;
  int _itemSeq = 0;
  final List<HttpRequest> received = [];

  String password = 'dev-pw-123';
  Duration loginDelay = Duration.zero;

  /// 非 null 时，POST /api/v1/items 一律以该状态码 + server_error 失败。
  int? forceItemStatus;

  /// true 时，cursor>0 的 sync 返回 409 full_sync_required。
  bool rejectIncrementalSync = false;

  Future<String> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
    return 'http://127.0.0.1:${_server!.port}';
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

  Future<void> _handle(HttpRequest req) async {
    received.add(req);
    final raw = await utf8.decoder.bind(req).join();
    final body = raw.isEmpty
        ? <String, Object?>{}
        : jsonDecode(raw) as Map<String, Object?>;
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
      if (forceItemStatus != null) {
        return _fail(req.response, forceItemStatus!, 'server_error', '服务器开小差了');
      }
      final key = req.headers.value('idempotency-key') ?? '';
      if (key.isNotEmpty && _idempotent.containsKey(key)) {
        return _json(req.response, _idempotent[key]!,
            headers: {'X-Idempotent-Replay': '1'});
      }
      final item =
          _newItem('${body['text']}', body['target_device'] as String?);
      itemsById[item['id'] as String] = item;
      recordChange('item', item['id'] as String, 'upsert');
      final result = {'item': item};
      if (key.isNotEmpty) _idempotent[key] = result;
      return _json(req.response, result);
    }
    final itemMatch = RegExp(r'^/api/v1/items/([^/]+)$').firstMatch(path);
    if (itemMatch != null && req.method == 'GET') {
      final item = itemsById[itemMatch.group(1)];
      if (item == null) return _fail(req.response, 404, 'not_found', '项目不存在');
      return _json(req.response, {'item': item});
    }
    return _fail(req.response, 404, 'not_found', '接口不存在');
  }
}
