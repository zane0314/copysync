import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
import 'memory_token_store.dart';

void main() {
  late FakeV1Server server;
  late AppState state;

  setUp(() async {
    server = FakeV1Server();
    state = AppState(
      api: ApiClient(await server.start()),
      tokenStore: MemoryTokenStore(),
    );
  });

  tearDown(() => server.stop());

  Future<bool> loginOk() => state.login(
        password: 'dev-pw-123',
        deviceName: 'Kimi Mac',
        platform: 'mac',
      );

  group('登录', () {
    test('成功：状态 success、token 存入安全存储、记录设备', () async {
      final ok = await loginOk();
      expect(ok, isTrue);
      expect(state.loginStatus, OpStatus.success);
      expect(state.isLoggedIn, isTrue);
      expect(state.device?.id, 'dev-1');
      expect(await state.tokenStore.read(), 'cps_tok_1');
    });

    test('密码错误：状态 error、显示服务端 message、不写 token', () async {
      final ok = await state.login(
        password: 'bad',
        deviceName: 'Kimi Mac',
        platform: 'mac',
      );
      expect(ok, isFalse);
      expect(state.loginStatus, OpStatus.error);
      expect(state.loginError, '密码错误');
      expect(state.isLoggedIn, isFalse);
      expect(await state.tokenStore.read(), isNull);
    });

    test('加载中防重复触发：并发两次只发一次请求', () async {
      server.loginDelay = const Duration(milliseconds: 200);
      final first = state.login(
          password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
      expect(state.loginStatus, OpStatus.loading);
      final second = await state.login(
          password: 'dev-pw-123', deviceName: 'Kimi Mac', platform: 'mac');
      expect(second, isFalse); // 被拒
      expect(await first, isTrue);
      final logins = server.received
          .where((r) => r.uri.path == '/api/v1/auth/login')
          .length;
      expect(logins, 1);
    });

    test('restoreSession 从安全存储恢复 token', () async {
      await state.tokenStore.save('cps_tok_1');
      await state.restoreSession();
      expect(state.isLoggedIn, isTrue);
    });
  });

  group('发送文本', () {
    setUp(() async {
      await loginOk();
      server.received.clear();
    });

    test('成功：状态 success 且新 item 出现在列表', () async {
      final ok = await state.sendText('你好世界');
      expect(ok, isTrue);
      expect(state.sendStatus, OpStatus.success);
      expect(state.items.map((i) => i.text), contains('你好世界'));
    });

    test('发送中防重：第二次调用被拒且只发一次请求', () async {
      final first = state.sendText('dup');
      expect(state.sendStatus, OpStatus.loading);
      final second = await state.sendText('dup');
      expect(second, isFalse);
      expect(await first, isTrue);
      final posts = server.received
          .where((r) => r.uri.path == '/api/v1/items' && r.method == 'POST')
          .length;
      expect(posts, 1);
    });

    test('失败：保留原列表、显示错误，修复后用同一幂等键重试成功', () async {
      await state.sendText('已有');
      server.forceItemStatus = 500;
      final ok = await state.sendText('会失败');
      expect(ok, isFalse);
      expect(state.sendStatus, OpStatus.error);
      expect(state.sendError, '服务器开小差了');
      expect(state.items.map((i) => i.text), isNot(contains('会失败')));
      final firstKey = server.received.last.headers.value('idempotency-key');
      expect(firstKey, isNotNull);

      server.forceItemStatus = null;
      final retry = await state.sendText('会失败');
      expect(retry, isTrue);
      final retryKey = server.received.last.headers.value('idempotency-key');
      expect(retryKey, firstKey); // 网络/服务器失败重试复用幂等键
    });

    test('空文本不发送请求', () async {
      final ok = await state.sendText('   ');
      expect(ok, isFalse);
      expect(state.sendStatus, OpStatus.error);
      expect(state.sendError, '文本不能为空');
      expect(server.received, isEmpty);
    });
  });

  group('刷新同步', () {
    setUp(() async {
      await loginOk();
    });

    test('全量同步拉取 item 详情与在线设备数', () async {
      await state.sendText('第一条');
      await state.refresh();
      expect(state.refreshStatus, OpStatus.success);
      expect(state.items.single.text, '第一条');
      expect(state.onlineDeviceCount, 1);
    });

    test('墓碑删除已存在的 item', () async {
      await state.sendText('将被删');
      await state.refresh();
      final id = state.items.single.id;
      server.itemsById.remove(id);
      server.recordChange('item', id, 'delete');
      await state.refresh();
      expect(state.items, isEmpty);
    });

    test('增量游标被拒时回退 cursor=0 全量同步', () async {
      await state.sendText('abc');
      await state.refresh();
      server.rejectIncrementalSync = true;
      await state.refresh();
      expect(state.refreshStatus, OpStatus.success);
      expect(state.items.map((i) => i.text), contains('abc'));
      final cursors = server.received
          .where((r) => r.uri.path == '/api/v1/sync')
          .map((r) => r.uri.queryParameters['cursor'])
          .toList();
      expect(cursors.last, '0');
    });

    test('刷新失败：保留原数据并显示错误', () async {
      await state.sendText('保留我');
      await state.refresh();
      await server.stop(); // 服务器挂掉
      await state.refresh();
      expect(state.refreshStatus, OpStatus.error);
      expect(state.refreshError, isNotNull);
      expect(state.items.single.text, '保留我');
      // 恢复供 tearDown
      server = FakeV1Server();
      state.api.baseUrl = await server.start();
      state.api.token = 'cps_tok_1';
    });
  });
}
