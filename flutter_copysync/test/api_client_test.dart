import 'dart:convert';
import 'dart:io';

import 'package:copysync/api/api_client.dart';
import 'fake_v1_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeV1Server server;
  late String baseUrl;

  setUp(() async {
    server = FakeV1Server();
    baseUrl = await server.start();
  });

  tearDown(() => server.stop());

  test('clearTemp 遇传输层瞬时中断（header 前断连）复用同一 idemKey 重试后成功', () async {
    server.clearTempTransportFailures = 1; // 首次销毁连接，重试应成功
    final client = ApiClient(baseUrl)..token = 'cps_tok_1';
    final result = await client.clearTemp(idemKey: 'idem-clear-1');
    expect(result['ok'], true);
    // 两次到达服务端：被中断的首次 + 成功的重试
    final clearTempReqs = server.received
        .where((r) => r.uri.path == '/api/v1/items/clear-temp')
        .toList();
    expect(clearTempReqs.length, 2);
    for (final r in clearTempReqs) {
      expect(r.headers.value('idempotency-key'), 'idem-clear-1',
          reason: '重试必须复用同一幂等键以保证恰好一次');
    }
  });

  test('clearTemp 传输错误超过重试次数仍失败则抛 network_error', () async {
    server.clearTempTransportFailures = 5; // 超过重试预算
    final client = ApiClient(baseUrl)..token = 'cps_tok_1';
    await expectLater(
      client.clearTemp(idemKey: 'idem-clear-2'),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'network_error')),
    );
  });

  test('login 成功返回 token 与设备信息，请求体含 password/device_name/platform',
      () async {
    final client = ApiClient(baseUrl);
    final result = await client.login(
      password: 'dev-pw-123',
      deviceName: 'Kimi Mac',
      platform: 'mac',
    );
    expect(result.token, 'cps_tok_1');
    expect(result.device.id, 'dev-1');
    expect(result.device.name, 'Kimi Mac');
    expect(result.device.platform, 'mac');
    expect(client.token, 'cps_tok_1');
  });

  test('login 密码错误抛出 401 invalid_credentials，message 可显示', () async {
    final client = ApiClient(baseUrl);
    try {
      await client.login(
          password: 'wrong', deviceName: 'Kimi Mac', platform: 'mac');
      fail('应抛出 ApiException');
    } on ApiException catch (e) {
      expect(e.status, 401);
      expect(e.code, 'invalid_credentials');
      expect(e.message, '密码错误');
    }
  });

  test('listDevices 携带 Bearer token 并解析在线状态', () async {
    final client = ApiClient(baseUrl);
    await client.login(
        password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
    final devices = await client.listDevices();
    expect(devices, hasLength(1));
    expect(devices.single.id, 'dev-1');
    expect(devices.single.online, isTrue);
    final req = server.received.last;
    expect(req.headers.value('authorization'), 'Bearer cps_tok_1');
  });

  test('未认证请求抛出 401 unauthorized', () async {
    final client = ApiClient(baseUrl);
    expect(
      () => client.listDevices(),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 401)
          .having((e) => e.code, 'code', 'unauthorized')),
    );
  });

  test('sync 传递 cursor 并解析 changes/tombstones/next_cursor', () async {
    final client = ApiClient(baseUrl);
    await client.login(
        password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
    server.recordChange('item', 'item-x', 'upsert');
    server.recordChange('item', 'item-y', 'delete');
    final page = await client.sync(0);
    expect(page.changes, hasLength(3)); // login 的 device upsert + 2 条
    expect(page.changes.first.seq, 1);
    expect(page.changes.last.entityId, 'item-y');
    expect(page.tombstones, hasLength(1));
    expect(page.tombstones.single.entityId, 'item-y');
    expect(page.nextCursor, 3);
    expect(server.received.last.uri.queryParameters['cursor'], '0');
  });

  test('sync 非法游标抛出 409 full_sync_required', () async {
    final client = ApiClient(baseUrl)..token = 'cps_tok_1';
    expect(
      () => client.sync(-1),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 409)
          .having((e) => e.code, 'code', 'full_sync_required')),
    );
  });

  test('createTextItem 发送 JSON 与幂等键并解析 item', () async {
    final client = ApiClient(baseUrl);
    await client.login(
        password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
    final item = await client.createTextItem('你好', idempotencyKey: 'k-1');
    expect(item.id, 'item-1');
    expect(item.text, '你好');
    expect(item.sourceDevice, 'dev-1');
    final req = server.received.last;
    expect(req.headers.contentType?.mimeType, 'application/json');
    expect(req.headers.value('idempotency-key'), 'k-1');
  });

  test('带 JSON 请求体的请求必须带 Content-Length（Python http.server 不支持 chunked）',
      () async {
    final client = ApiClient(baseUrl);
    await client.login(
        password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
    final loginReq = server.received.last;
    expect(loginReq.headers.value('transfer-encoding'), isNull);
    expect(int.parse(loginReq.headers.value('content-length')!), greaterThan(0));
    await client.createTextItem('你好', idempotencyKey: 'k-1');
    final postReq = server.received.last;
    expect(postReq.headers.value('transfer-encoding'), isNull);
    expect(int.parse(postReq.headers.value('content-length')!), greaterThan(0));
  });

  test('同一幂等键重发返回第一次结果且不重复创建', () async {
    final client = ApiClient(baseUrl);
    await client.login(
        password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
    final first = await client.createTextItem('hi', idempotencyKey: 'k-dup');
    final second = await client.createTextItem('hi', idempotencyKey: 'k-dup');
    expect(second.id, first.id);
    final page = await client.sync(0);
    final itemChanges =
        page.changes.where((c) => c.entity == 'item').toList();
    expect(itemChanges, hasLength(1));
  });

  group('uploadFile', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('copysync_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Future<String> writeTemp(String name, List<int> bytes) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);
      return file.path;
    }

    test('multipart 格式正确：边界/字段/content-disposition，显式 Content-Length',
        () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final path = await writeTemp('note.txt', utf8.encode('文件内容abc'));
      final item = await client.uploadFile(path, idemKey: 'k-file');
      expect(item.kind, 'file');
      expect(item.name, 'note.txt');
      expect(item.size, utf8.encode('文件内容abc').length);

      final req = server.received.last;
      final contentType = req.headers.contentType!;
      expect(contentType.mimeType, 'multipart/form-data');
      expect(contentType.parameters['boundary'], isNotEmpty);
      // Python http.server 不支持 chunked，必须显式 Content-Length。
      expect(req.headers.value('transfer-encoding'), isNull);
      expect(req.headers.value('content-length'),
          '${server.receivedBodies.last.length}');
      expect(req.headers.value('idempotency-key'), 'k-file');

      final raw = latin1.decode(server.receivedBodies.last);
      final boundary = contentType.parameters['boundary']!;
      expect(raw, contains('--$boundary\r\n'));
      expect(raw,
          contains('Content-Disposition: form-data; name="file"; filename="note.txt"'));
      expect(raw, contains('--$boundary--'));
      final filePart = server.lastMultipart['file']!;
      expect(filePart.filename, 'note.txt');
      expect(filePart.bytes, utf8.encode('文件内容abc'));
    });

    test('携带 note/target_device 表单字段与 clipboard_variant 文件', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final pngBytes = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
      final path = await writeTemp('pic.png', pngBytes);
      final item = await client.uploadFile(
        path,
        clipboardVariantPath: path,
        targetDevice: 'dev-9',
        note: '备注',
      );
      expect(item.kind, 'image');
      expect(item.targetDevice, 'dev-9');
      final variant = server.lastMultipart['clipboard_variant']!;
      expect(variant.filename, 'pic.png');
      expect(variant.bytes, pngBytes);
      expect(server.lastMultipart['note']!.text, '备注');
      expect(server.lastMultipart['target_device']!.text, 'dev-9');
    });

    test('413 file_too_large 与 507 storage_full 映射为 ApiException code',
        () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final path = await writeTemp('big.bin', [1, 2, 3]);
      server.forceItemStatus = 413;
      server.forceItemCode = 'file_too_large';
      server.forceItemMessage = '超过单文件上限';
      await expectLater(
        () => client.uploadFile(path),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 413)
            .having((e) => e.code, 'code', 'file_too_large')),
      );
      server.forceItemStatus = 507;
      server.forceItemCode = 'storage_full';
      await expectLater(
        () => client.uploadFile(path),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 507)
            .having((e) => e.code, 'code', 'storage_full')),
      );
    });

    test('超过 100MB 上限时客户端直接抛 413，不发起请求', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      // 稀疏文件：长度超上限但不实际写入 100MB，length() 仍报完整长度。
      final path = '${tempDir.path}/huge.bin';
      final raf = await File(path).open(mode: FileMode.write);
      await raf.setPosition(ApiClient.maxUploadBytes + 1);
      await raf.writeByte(0);
      await raf.close();

      final before = server.received.length;
      await expectLater(
        () => client.uploadFile(path),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 413)
            .having((e) => e.code, 'code', 'file_too_large')),
      );
      // 提前拦截：不应触达服务端（避免服务端提前 413 关连接的 header 错误）。
      expect(server.received.length, before);
    });

    test('同一幂等键重放返回首次结果', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final path = await writeTemp('a.txt', utf8.encode('a'));
      final first = await client.uploadFile(path, idemKey: 'k-dup-file');
      final second = await client.uploadFile(path, idemKey: 'k-dup-file');
      expect(second.id, first.id);
      expect(server.itemsById, hasLength(1));
    });
  });

  group('downloadContent', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('copysync_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('按 variant 下载字节并携带 Bearer token', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final path = '${tempDir.path}/p.png';
      await File(path).writeAsBytes([9, 8, 7]);
      final item = await client.uploadFile(path, clipboardVariantPath: path);
      final original = await client.downloadContent(item.id);
      expect(original, [9, 8, 7]);
      final req = server.received.last;
      expect(req.uri.queryParameters['variant'], 'original');
      expect(req.headers.value('authorization'), 'Bearer cps_tok_1');
      final clipboard =
          await client.downloadContent(item.id, variant: 'clipboard');
      expect(clipboard, [9, 8, 7]);
      expect(server.received.last.uri.queryParameters['variant'], 'clipboard');
    });

    test('无 clipboard 变体时抛出 404 variant_missing', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final path = '${tempDir.path}/p.png';
      await File(path).writeAsBytes([9, 8, 7]);
      final item = await client.uploadFile(path);
      await expectLater(
        () => client.downloadContent(item.id, variant: 'clipboard'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'variant_missing')),
      );
    });
  });

  group('deliveries/ack', () {
    test('createDelivery 定向发送并解析 delivery，携带幂等键', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final item = await client.createTextItem('定向内容');
      final delivery = await client.createDelivery(item.id,
          targetDevice: 'dev-1', idemKey: 'k-dlv');
      expect(delivery.itemId, item.id);
      expect(delivery.sourceDevice, 'dev-1');
      expect(delivery.targetDevice, 'dev-1');
      expect(delivery.status, 'waiting');
      final req = server.received.last;
      expect(req.uri.path, '/api/v1/items/${item.id}/deliveries');
      expect(req.headers.value('idempotency-key'), 'k-dlv');
    });

    test('createDelivery 目标不存在抛出 404 device_not_found', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final item = await client.createTextItem('x');
      await expectLater(
        () => client.createDelivery(item.id, targetDevice: 'ghost'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'device_not_found')),
      );
    });

    test('ackDelivery 更新状态；非目标设备抛出 403 device_mismatch', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final item = await client.createTextItem('x');
      final delivery =
          await client.createDelivery(item.id, targetDevice: 'dev-1');
      final acked =
          await client.ackDelivery(delivery.id, status: 'downloaded');
      expect(acked.id, delivery.id);
      expect(acked.status, 'downloaded');
      expect(server.received.last.uri.path,
          '/api/v1/deliveries/${delivery.id}/ack');

      // 另一设备的投递：本 token（dev-1）不能确认。
      server.deliveriesById['dlv-other'] = {
        'id': 'dlv-other',
        'item_id': item.id,
        'source_device': 'dev-9',
        'target_device': 'dev-9',
        'status': 'waiting',
        'created_at': 1,
        'updated_at': 1,
      };
      await expectLater(
        () => client.ackDelivery('dlv-other'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.code, 'code', 'device_mismatch')),
      );
    });
  });

  group('patchItem/deleteItem/usage/logout', () {
    test('patchItem 图钉与备注，解析 pinned/note 字段', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final item = await client.createTextItem('pin me');
      expect(item.pinned, isFalse);
      final patched =
          await client.patchItem(item.id, pinned: true, note: '重要');
      expect(patched.pinned, isTrue);
      expect(patched.note, '重要');
      expect(server.received.last.method, 'PATCH');
    });

    test('patchItem ttl 续期更新 expiresAt', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final item = await client.createTextItem('renew me');
      final renewed = await client.patchItem(item.id, ttl: 7 * 86400);
      expect(renewed.expiresAt, 1000000 + 7 * 86400);
    });

    test('deleteItem 删除并产生墓碑；重复删除抛 404', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final item = await client.createTextItem('bye');
      await client.deleteItem(item.id);
      expect(server.itemsById, isEmpty);
      final page = await client.sync(0);
      expect(page.tombstones.map((t) => t.entityId), contains(item.id));
      await expectLater(
        () => client.deleteItem(item.id),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'item_not_found')),
      );
    });

    test('usage 解析容量与上限', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      final usage = await client.usage();
      expect(usage.tempBytes, 2048);
      expect(usage.pinnedBytes, 1024);
      expect(usage.totalBytes, 3072);
      expect(usage.tempLimit, 2097152);
      expect(usage.pinnedLimit, 1048576);
      expect(usage.maxFileBytes, 10485760);
    });

    test('logout 调用服务端撤销端点', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      await client.logout();
      expect(server.received.last.uri.path, '/api/v1/auth/logout');
      expect(server.received.last.method, 'POST');
    });

    test('changePassword 成功：请求体含当前/新密码且服务端密码更新', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      await client.changePassword(
          currentPassword: 'dev-pw-123', newPassword: 'new-password-456');
      expect(server.password, 'new-password-456');
      final req = server.received.last;
      expect(req.uri.path, '/api/v1/auth/password');
      expect(req.headers.value('authorization'), 'Bearer cps_tok_1');
    });

    test('changePassword 当前密码错误抛出 401 invalid_credentials', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      try {
        await client.changePassword(
            currentPassword: 'wrong', newPassword: 'new-password-456');
        fail('应抛出 ApiException');
      } on ApiException catch (e) {
        expect(e.status, 401);
        expect(e.code, 'invalid_credentials');
      }
      expect(server.password, 'dev-pw-123'); // 未改动
    });

    test('clearAll 携带幂等键并解析 deleted', () async {
      final client = ApiClient(baseUrl)..token = 'cps_tok_1';
      await client.createTextItem('待清空');
      final result = await client.clearAll(idemKey: 'k-clear-1');
      expect((result['deleted'] as num).toInt(), greaterThanOrEqualTo(1));
      expect(server.itemsById, isEmpty);
      expect(
          server.received.last.headers.value('idempotency-key'), 'k-clear-1');
    });
  });
}
