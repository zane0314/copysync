import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

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
    this.mime = '',
    this.size = 0,
    this.createdAt = 0,
    this.expiresAt = 0,
    this.pinned = false,
    this.note = '',
  });

  factory Item.fromJson(Map<String, Object?> json) => Item(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        text: json['text'] as String? ?? '',
        name: json['name'] as String? ?? '',
        mime: json['mime'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        // 图钉条目 expires_at 为 null。
        expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
        pinned: json['pinned'] == 1 || json['pinned'] == true,
        note: json['note'] as String? ?? '',
        sourceDevice: json['source_device'] as String? ?? '',
        targetDevice: json['target_device'] as String? ?? '',
      );

  final String id;
  final String kind;
  final String text;
  final String name;
  final String mime;
  final int size;
  final int createdAt;
  final int expiresAt;
  final bool pinned;
  final String note;
  final String sourceDevice;
  final String targetDevice;
}

/// 一次定向投递（对应服务端 deliveries 表行）。
class Delivery {
  Delivery({
    required this.id,
    required this.itemId,
    required this.sourceDevice,
    required this.targetDevice,
    required this.status,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  factory Delivery.fromJson(Map<String, Object?> json) => Delivery(
        id: json['id'] as String? ?? '',
        itemId: json['item_id'] as String? ?? '',
        sourceDevice: json['source_device'] as String? ?? '',
        targetDevice: json['target_device'] as String? ?? '',
        status: json['status'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String itemId;
  final String sourceDevice;
  final String targetDevice;
  final String status;
  final int createdAt;
  final int updatedAt;
}

/// 容量与限制（`GET /api/v1/usage`）。
class UsageInfo {
  UsageInfo({
    required this.tempBytes,
    required this.pinnedBytes,
    required this.totalBytes,
    required this.pinnedLimit,
    required this.tempLimit,
    required this.maxFileBytes,
  });

  factory UsageInfo.fromJson(Map<String, Object?> json) {
    final limits = (json['limits'] as Map?)?.cast<String, Object?>() ?? {};
    int intOf(Map<String, Object?> map, String key) =>
        (map[key] as num?)?.toInt() ?? 0;
    return UsageInfo(
      tempBytes: intOf(json, 'temp_bytes'),
      pinnedBytes: intOf(json, 'pinned_bytes'),
      totalBytes: intOf(json, 'total_bytes'),
      pinnedLimit: intOf(limits, 'pinned'),
      tempLimit: intOf(limits, 'temp'),
      maxFileBytes: intOf(limits, 'max_file'),
    );
  }

  final int tempBytes;
  final int pinnedBytes;
  final int totalBytes;
  final int pinnedLimit;
  final int tempLimit;
  final int maxFileBytes;
}

/// `/api/v1` 客户端，直接用 dart:io HttpClient，不引入第三方网络库。
class ApiClient {
  ApiClient(this.baseUrl);

  /// 服务端基址（登录页可修改，如 `http://127.0.0.1:15101`）。
  String baseUrl;

  /// 登录成功后持有的设备 Token；也允许从安全存储恢复后注入。
  String? token;

  final _boundaryRandom = Random();

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

  /// 读取 `/api/v1/events` 的 SSE 版本通知；取消订阅会关闭底层连接。
  Stream<int> events() {
    final controller = StreamController<int>();
    HttpClient? client;
    var cancelled = false;

    Future<void> connect() async {
      client = HttpClient();
      try {
        final request = await client!.getUrl(
          Uri.parse('$baseUrl/api/v1/events'),
        );
        if (token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await _decodeResponse(response);
          throw StateError('unreachable');
        }
        var buffer = '';
        await for (final chunk in response.transform(utf8.decoder)) {
          if (cancelled) break;
          buffer += chunk;
          var end = buffer.indexOf('\n\n');
          while (end >= 0) {
            final frame = buffer.substring(0, end);
            buffer = buffer.substring(end + 2);
            for (final line in frame.split('\n')) {
              if (!line.startsWith('data:')) continue;
              final version = int.tryParse(line.substring(5).trim());
              if (version != null && !cancelled) controller.add(version);
            }
            end = buffer.indexOf('\n\n');
          }
        }
        if (!cancelled) await controller.close();
      } catch (error, stack) {
        if (!cancelled) {
          controller.addError(_networkException(error), stack);
          await controller.close();
        }
      } finally {
        client?.close(force: true);
        client = null;
      }
    }

    controller.onListen = () {
      unawaited(connect());
    };
    controller.onCancel = () {
      cancelled = true;
      client?.close(force: true);
    };
    return controller.stream;
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

  /// 客户端上传上限（与服务端 MAX_FILE_BYTES=100MB 对齐），提前拦截避免
  /// 服务端提前 413 关连接导致 "connection closed before full header"。
  static const int maxUploadBytes = 100 * 1024 * 1024;

  /// 上传文件/图片（multipart/form-data）；图片可同时带 clipboard_variant。
  /// [path] 为本地文件路径，文件名取路径最后一段；MIME 按扩展名推断，
  /// 服务端按 MIME 决定 kind（image/* → image，否则 file）。
  ///
  /// 主文件以 openRead() 流式发送，不整块读入内存——避免大文件 readAsBytes()
  /// 导致的 OOM 强退（从"选择文件"选大文件上传屡次崩溃的根因）。
  Future<Item> uploadFile(
    String path, {
    String? clipboardVariantPath,
    String? targetDevice,
    String? idemKey,
    String? note,
  }) async {
    final file = File(path);
    final fileLength = await file.length();
    if (fileLength > maxUploadBytes) {
      throw ApiException(413, 'file_too_large', '文件超过 100MB 上限，无法上传');
    }
    final name = _basename(path);
    // variant 与主文件一样流式发送，避免图片副本整块读入内存。
    final variantFile = clipboardVariantPath != null &&
            clipboardVariantPath.isNotEmpty
        ? File(clipboardVariantPath)
        : null;
    final variantLength = variantFile == null ? 0 : await variantFile.length();
    String? variantName;
    if (variantFile != null) {
      variantName = _basename(variantFile.path);
    }
    final boundary =
        '----copysync${DateTime.now().microsecondsSinceEpoch}${_boundaryRandom.nextInt(1 << 32)}';

    // 头部：表单字段 + 主文件分段头（截止到文件内容前的空行）。
    final head = BytesBuilder();
    final fields = <String, String>{
      if (note != null && note.isNotEmpty) 'note': note,
      if (targetDevice != null && targetDevice.isNotEmpty)
        'target_device': targetDevice,
    };
    for (final entry in fields.entries) {
      head.add(utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="${entry.key}"\r\n'
          '\r\n'
          '${entry.value}\r\n'));
    }
    head.add(utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$name"\r\n'
        'Content-Type: ${_mimeOf(name)}\r\n'
        '\r\n'));
    final headBytes = head.toBytes();

    // 主文件后的分段头；variant 内容单独 openRead()，最后再写结束边界。
    final variantHead = BytesBuilder();
    if (variantFile != null) {
      variantHead.add(utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="clipboard_variant"; filename="$variantName"\r\n'
          'Content-Type: ${_mimeOf(variantName!)}\r\n'
          '\r\n'));
    }
    final variantHeadBytes = variantHead.toBytes();
    final tailBytes = utf8.encode('--$boundary--\r\n');

    final client = HttpClient();
    try {
      final request = await client.openUrl(
          'POST', Uri.parse('$baseUrl/api/v1/items'));
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (idemKey != null && idemKey.isNotEmpty) {
        request.headers.set('Idempotency-Key', idemKey);
      }
      request.headers.contentType = ContentType('multipart', 'form-data',
          parameters: {'boundary': boundary});
      // Python http.server 不支持 chunked 请求体，必须显式 Content-Length。
      request.contentLength = headBytes.length +
          fileLength +
          2 +
          (variantFile == null
              ? 0
              : variantHeadBytes.length + variantLength + 2) +
          tailBytes.length;
      request.add(headBytes);
      await request.addStream(file.openRead());
      request.add(utf8.encode('\r\n'));
      if (variantFile != null) {
        request.add(variantHeadBytes);
        await request.addStream(variantFile.openRead());
        request.add(utf8.encode('\r\n'));
      }
      request.add(tailBytes);
      final response = await request.close();
      final decoded = await _decodeResponse(response);
      return Item.fromJson(decoded['item'] as Map<String, Object?>);
    } on SocketException catch (e) {
      throw ApiException(0, 'network_error', '无法连接服务器：${e.message}');
    } on HttpException catch (e) {
      throw ApiException(0, 'network_error', '网络错误：${e.message}');
    } on OSError catch (e) {
      // connect 阶段的对端重置等底层错误（不经 SocketException 包装）。
      throw ApiException(0, 'network_error', '网络错误：${e.message}');
    } finally {
      client.close();
    }
  }

  /// 下载项目内容字节；[variant] 为 original（默认）或 clipboard。
  Future<Uint8List> downloadContent(String id, {String variant = 'original'}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('GET',
          Uri.parse('$baseUrl/api/v1/items/$id/content?variant=$variant'));
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return await consolidateHttpClientResponseBytes(response);
      }
      await _decodeResponse(response); // 非 2xx 一律抛 ApiException
      throw StateError('unreachable');
    } on SocketException catch (e) {
      throw ApiException(0, 'network_error', '无法连接服务器：${e.message}');
    } on HttpException catch (e) {
      throw ApiException(0, 'network_error', '网络错误：${e.message}');
    } on OSError catch (e) {
      // connect 阶段的对端重置等底层错误（不经 SocketException 包装）。
      throw ApiException(0, 'network_error', '网络错误：${e.message}');
    } finally {
      client.close();
    }
  }

  /// 撤销当前 token（服务端失败时调用方自行决定本地清理策略）。
  Future<void> logout() => _request('POST', '/api/v1/auth/logout');

  /// 修改密码：成功后服务端撤销全部设备 Token（含当前），
  /// 调用方必须清空本地登录态并回到登录页。
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      _request('POST', '/api/v1/auth/password', jsonBody: {
        'current_password': currentPassword,
        'new_password': newPassword,
      });

  /// 彻底清空全部内容（含已固定），返回 {"deleted","bytes"}。
  Future<Map<String, Object?>> clearAll({String? idemKey}) async {
    return _request(
      'POST',
      '/api/v1/items/clear-all',
      jsonBody: const {},
      headers: {
        if (idemKey != null && idemKey.isNotEmpty) 'Idempotency-Key': idemKey,
      },
      // 幂等操作：对传输层瞬时错误重试一次，缓解偶发的 header 前连接重置。
      retryOnNetworkError: 1,
    );
  }

  /// 清理未固定的临时内容，返回 {"deleted","bytes"}。
  Future<Map<String, Object?>> clearTemp({String? idemKey}) async {
    return _request(
      'POST',
      '/api/v1/items/clear-temp',
      jsonBody: const {},
      headers: {
        if (idemKey != null && idemKey.isNotEmpty) 'Idempotency-Key': idemKey,
      },
      // 幂等操作：对传输层瞬时错误重试一次，缓解偶发的 header 前连接重置。
      retryOnNetworkError: 1,
    );
  }

  /// 图钉、备注和有效期变更（ttl 为相对秒数，服务端 clamp 到 300..7 天）。
  Future<Item> patchItem(
    String id, {
    bool? pinned,
    String? note,
    int? ttl,
    String? idemKey,
  }) async {
    final body = await _request(
      'PATCH',
      '/api/v1/items/$id',
      jsonBody: {
        'pinned': ?pinned,
        'note': ?note,
        'ttl': ?ttl,
      },
      headers: {
        if (idemKey != null && idemKey.isNotEmpty) 'Idempotency-Key': idemKey,
      },
    );
    return Item.fromJson(body['item'] as Map<String, Object?>);
  }

  /// 删除项目并记录墓碑。
  Future<void> deleteItem(String id, {String? idemKey}) => _request(
        'DELETE',
        '/api/v1/items/$id',
        headers: {
          if (idemKey != null && idemKey.isNotEmpty) 'Idempotency-Key': idemKey,
        },
      );

  /// 定向发送到目标设备。
  Future<Delivery> createDelivery(
    String itemId, {
    required String targetDevice,
    String? idemKey,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/items/$itemId/deliveries',
      jsonBody: {'target_device': targetDevice},
      headers: {
        if (idemKey != null && idemKey.isNotEmpty) 'Idempotency-Key': idemKey,
      },
    );
    return Delivery.fromJson(body['delivery'] as Map<String, Object?>);
  }

  /// 收件确认（只能由目标设备的 token 调用；status 为
  /// waiting/delivered/downloaded/copied/failed）。
  Future<Delivery> ackDelivery(
    String deliveryId, {
    String status = 'delivered',
    String? idemKey,
  }) async {
    final body = await _request(
      'POST',
      '/api/v1/deliveries/$deliveryId/ack',
      jsonBody: {'status': status},
      headers: {
        if (idemKey != null && idemKey.isNotEmpty) 'Idempotency-Key': idemKey,
      },
    );
    return Delivery.fromJson(body['delivery'] as Map<String, Object?>);
  }

  /// 容量与限制。
  Future<UsageInfo> usage() async {
    final body = await _request('GET', '/api/v1/usage');
    return UsageInfo.fromJson(body);
  }

  /// 投递列表（接收通知与下载对账用；响应含 history 字段，这里只取 deliveries）。
  Future<List<Delivery>> listDeliveries() async {
    final body = await _request('GET', '/api/v1/deliveries');
    return (body['deliveries'] as List<Object?>)
        .map((d) => Delivery.fromJson(d as Map<String, Object?>))
        .toList();
  }

  /// 条目内容下载地址（Android 端交给 DownloadManager 时使用）。
  String contentUrl(String id, {String variant = 'original'}) =>
      '$baseUrl/api/v1/items/$id/content?variant=$variant';

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  static String _mimeOf(String filename) {
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
      'zip': 'application/zip',
    };
    return mimes[ext] ?? 'application/octet-stream';
  }

  /// [retryOnNetworkError] 仅供幂等操作（携带 Idempotency-Key 或天然幂等）使用：
  /// 遇传输层瞬时错误（SocketException/HttpException/OSError，如 header 前连接重置）时，
  /// 复用同一请求头（含同一 Idempotency-Key）重试，服务端命中幂等键返回缓存结果，保证恰好一次。
  /// 不重试 HTTP 错误响应（那些经 _decodeResponse 抛 ApiException，不属传输层错误）。
  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    Map<String, String>? headers,
    bool authenticated = true,
    int retryOnNetworkError = 0,
  }) async {
    var attemptsLeft = retryOnNetworkError;
    while (true) {
      final client = HttpClient();
      try {
        final request = await client.openUrl(method, Uri.parse('$baseUrl$path'));
        if (authenticated && token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        headers?.forEach(request.headers.set);
        if (jsonBody != null) {
          request.headers.contentType = ContentType.json;
          final encoded = utf8.encode(jsonEncode(jsonBody));
          // Python http.server 不支持 chunked 请求体，必须显式 Content-Length。
          request.contentLength = encoded.length;
          request.add(encoded);
        }
        final response = await request.close();
        return await _decodeResponse(response);
      } on SocketException catch (e) {
        if (attemptsLeft > 0) {
          attemptsLeft -= 1;
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        throw ApiException(0, 'network_error', '无法连接服务器：${e.message}');
      } on HttpException catch (e) {
        if (attemptsLeft > 0) {
          attemptsLeft -= 1;
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        throw ApiException(0, 'network_error', '网络错误：${e.message}');
      } on OSError catch (e) {
        // connect 阶段的对端重置等底层错误（不经 SocketException 包装）。
        if (attemptsLeft > 0) {
          attemptsLeft -= 1;
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        throw ApiException(0, 'network_error', '网络错误：${e.message}');
      } finally {
        client.close();
      }
    }
  }

  static const Duration _retryDelay = Duration(milliseconds: 150);

  ApiException _networkException(Object error) => switch (error) {
    ApiException e => e,
    SocketException e => ApiException(
      0,
      'network_error',
      '无法连接服务器：${e.message}',
    ),
    HttpException e => ApiException(0, 'network_error', '网络错误：${e.message}'),
    OSError e => ApiException(0, 'network_error', '网络错误：${e.message}'),
    _ => ApiException(0, 'network_error', '网络错误：$error'),
  };

  /// 读取响应：2xx 解析 JSON map；否则把错误信封映射为 ApiException。
  Future<Map<String, Object?>> _decodeResponse(HttpClientResponse response) async {
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
  }
}
