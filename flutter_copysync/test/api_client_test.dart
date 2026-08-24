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
}
