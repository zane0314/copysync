import 'dart:convert';
import 'dart:io';

/// v1 API 错误信封对应的异常（code 稳定、message 可直接显示）。
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, {this.details});

  final int status;
  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'ApiException($status, $code, $message)';
}

class Device {
  Device({
    required this.id,
    required this.name,
    required this.platform,
    this.online = false,
    this.lastSeenAt = 0,
  });

  factory Device.fromJson(Map<String, Object?> json) => Device(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        online: json['online'] as bool? ?? false,
        lastSeenAt: (json['last_seen_at'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String name;
  final String platform;
  final bool online;
  final int lastSeenAt;
}

class LoginResult {
  LoginResult({required this.token, required this.device});

  final String token;
  final Device device;
}

class SyncChange {
  SyncChange({
    required this.seq,
    required this.entity,
    required this.entityId,
    required this.op,
  });

  factory SyncChange.fromJson(Map<String, Object?> json) => SyncChange(
        seq: (json['seq'] as num).toInt(),
        entity: json['entity'] as String? ?? '',
        entityId: json['entity_id'] as String? ?? '',
        op: json['op'] as String? ?? '',
      );

  final int seq;
  final String entity;
  final String entityId;
  final String op;
}

class Tombstone {
  Tombstone({required this.entity, required this.entityId});

  factory Tombstone.fromJson(Map<String, Object?> json) => Tombstone(
        entity: json['entity'] as String? ?? '',
        entityId: json['entity_id'] as String? ?? '',
      );

  final String entity;
  final String entityId;
}

class SyncPage {
  SyncPage({
    required this.changes,
    required this.tombstones,
    required this.nextCursor,
  });

  final List<SyncChange> changes;
  final List<Tombstone> tombstones;
  final int nextCursor;
}

class Item {
  Item({
    required this.id,
    required this.kind,
    required this.text,
    required this.sourceDevice,
    required this.targetDevice,
    this.name = '',
    this.size = 0,
    this.createdAt = 0,
    this.expiresAt = 0,
  });

  factory Item.fromJson(Map<String, Object?> json) => Item(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        text: json['text'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
        sourceDevice: json['source_device'] as String? ?? '',
        targetDevice: json['target_device'] as String? ?? '',
      );

  final String id;
  final String kind;
  final String text;
  final String name;
  final int size;
  final int createdAt;
  final int expiresAt;
  final String sourceDevice;
  final String targetDevice;
}

/// `/api/v1` 客户端，直接用 dart:io HttpClient，不引入第三方网络库。
class ApiClient {
  ApiClient(this.baseUrl);

  /// 服务端基址（登录页可修改，如 `http://127.0.0.1:15101`）。
  String baseUrl;

  /// 登录成功后持有的设备 Token；也允许从安全存储恢复后注入。
  String? token;

  Future<LoginResult> login({
    required String password,
    required String deviceName,
    required String platform,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/auth/login',
      jsonBody: {
        'password': password,
        'device_name': deviceName,
        'platform': platform,
      },
      authenticated: false,
    );
    final result = LoginResult(
      token: body['token'] as String,
      device: Device.fromJson(body['device'] as Map<String, Object?>),
    );
    token = result.token;
    return result;
  }

  Future<List<Device>> listDevices() async {
    final body = await _request('GET', '/api/v1/devices');
    return (body['devices'] as List<Object?>)
        .map((d) => Device.fromJson(d as Map<String, Object?>))
        .toList();
  }

  Future<SyncPage> sync(int cursor) async {
    final body = await _request('GET', '/api/v1/sync?cursor=$cursor');
    return SyncPage(
      changes: (body['changes'] as List<Object?>)
          .map((c) => SyncChange.fromJson(c as Map<String, Object?>))
          .toList(),
      tombstones: (body['tombstones'] as List<Object?>)
          .map((t) => Tombstone.fromJson(t as Map<String, Object?>))
          .toList(),
      nextCursor: (body['next_cursor'] as num).toInt(),
    );
  }

  Future<Item> getItem(String id) async {
    final body = await _request('GET', '/api/v1/items/$id');
    return Item.fromJson(body['item'] as Map<String, Object?>);
  }

  Future<Item> createTextItem(
    String text, {
    String? targetDevice,
    String? idempotencyKey,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/items',
      jsonBody: {
        'kind': 'text',
        'text': text,
        if (targetDevice != null && targetDevice.isNotEmpty)
          'target_device': targetDevice,
      },
      headers: {
        if (idempotencyKey != null && idempotencyKey.isNotEmpty)
          'Idempotency-Key': idempotencyKey,
      },
    );
    return Item.fromJson(body['item'] as Map<String, Object?>);
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    Map<String, String>? headers,
    bool authenticated = true,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      if (authenticated && token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      headers?.forEach(request.headers.set);
      if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(jsonBody));
      }
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      Object? decoded;
      try {
        decoded = raw.isEmpty ? null : jsonDecode(raw);
      } on FormatException {
        decoded = null;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (decoded as Map?)?.cast<String, Object?>() ?? {};
      }
      final error = (decoded as Map?)?['error'];
      if (error is Map) {
        throw ApiException(
          response.statusCode,
          error['code'] as String? ?? 'unknown',
          error['message'] as String? ?? '请求失败',
          details: error['details'],
        );
      }
      throw ApiException(response.statusCode, 'http_error', '请求失败（HTTP ${response.statusCode}）');
    } on SocketException catch (e) {
      throw ApiException(0, 'network_error', '无法连接服务器：${e.message}');
    } on HttpException catch (e) {
      throw ApiException(0, 'network_error', '网络错误：${e.message}');
    } finally {
      client.close();
    }
  }
}
