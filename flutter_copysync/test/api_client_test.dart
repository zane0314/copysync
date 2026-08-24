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
}
