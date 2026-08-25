import 'dart:convert';
import 'dart:io';

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

  group('发送文件/图片', () {
    late Directory tempDir;

    setUp(() async {
      await loginOk();
      server.received.clear();
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

    test('sendFile 成功：状态 success 且文件 item 出现在列表', () async {
      final path = await writeTemp('报告.txt', utf8.encode('内容'));
      final ok = await state.sendFile(path);
      expect(ok, isTrue);
      expect(state.sendStatus, OpStatus.success);
      final item = state.items.single;
      expect(item.kind, 'file');
      expect(item.name, '报告.txt');
    });

    test('sendImage 成功：kind 为 image 且携带 clipboard_variant', () async {
      final path = await writeTemp('pic.png', [0x89, 0x50, 1, 2]);
      final ok = await state.sendImage(path);
      expect(ok, isTrue);
      expect(state.items.single.kind, 'image');
      expect(server.lastMultipart['clipboard_variant']?.filename, 'pic.png');
    });

    test('发送中防重：第二次调用被拒且只发一次请求', () async {
      final path = await writeTemp('a.txt', utf8.encode('a'));
      final first = state.sendFile(path);
      expect(state.sendStatus, OpStatus.loading);
      final second = await state.sendFile(path);
      expect(second, isFalse);
      expect(await first, isTrue);
      final posts = server.received
          .where((r) => r.uri.path == '/api/v1/items' && r.method == 'POST')
          .length;
      expect(posts, 1);
    });

    test('失败保留列表与幂等键，修复后用同一幂等键重试成功', () async {
      final path = await writeTemp('b.txt', utf8.encode('b'));
      server.forceItemStatus = 500;
      final ok = await state.sendFile(path);
      expect(ok, isFalse);
      expect(state.sendStatus, OpStatus.error);
      expect(state.sendError, '服务器开小差了');
      expect(state.items, isEmpty);
      final firstKey = server.received.last.headers.value('idempotency-key');
      expect(firstKey, isNotNull);

      server.forceItemStatus = null;
      final retry = await state.sendFile(path);
      expect(retry, isTrue);
      expect(server.received.last.headers.value('idempotency-key'), firstKey);
      expect(state.items.single.name, 'b.txt');
    });

    test('文件不存在不发送请求', () async {
      final ok = await state.sendFile('${tempDir.path}/不存在.txt');
      expect(ok, isFalse);
      expect(state.sendStatus, OpStatus.error);
      expect(state.sendError, contains('文件不存在'));
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

  group('传输与网盘操作', () {
    setUp(() async {
      await loginOk();
    });

    test('sendToDevice 创建投递记录，状态流转 success', () async {
      await state.sendText('定向');
      final item = state.items.single;
      final ok = await state.sendToDevice(item.id, 'dev-1');
      expect(ok, isTrue);
      expect(state.deliveries.single.itemId, item.id);
      expect(state.deliveries.single.targetDevice, 'dev-1');
      expect(state.entryOp(item.id), OpStatus.success);
    });

    test('sendToDevice 进行中防重：同一条目第二次被拒', () async {
      await state.sendText('定向');
      final item = state.items.single;
      final first = state.sendToDevice(item.id, 'dev-1');
      expect(state.entryOp(item.id), OpStatus.loading);
      final second = await state.sendToDevice(item.id, 'dev-1');
      expect(second, isFalse);
      expect(await first, isTrue);
      final posts = server.received
          .where((r) => r.uri.path.endsWith('/deliveries'))
          .length;
      expect(posts, 1);
    });

    test('sendToDevice 失败：状态 error、记录原因、可重试', () async {
      await state.sendText('定向');
      final item = state.items.single;
      final ok = await state.sendToDevice(item.id, 'ghost');
      expect(ok, isFalse);
      expect(state.entryOp(item.id), OpStatus.error);
      expect(state.entryError(item.id), '目标设备不存在');
      expect(state.deliveries, isEmpty);
      final retry = await state.sendToDevice(item.id, 'dev-1');
      expect(retry, isTrue);
    });

    test('ackDelivery 更新本地投递状态', () async {
      await state.sendText('定向');
      final item = state.items.single;
      await state.sendToDevice(item.id, 'dev-1');
      final delivery = state.deliveries.single;
      final ok = await state.ackDelivery(delivery.id, status: 'downloaded');
      expect(ok, isTrue);
      expect(state.deliveries.single.status, 'downloaded');
    });

    test('refresh 收集 sync 中出现的 delivery 变化', () async {
      await state.sendText('定向');
      await state.sendToDevice(state.items.single.id, 'dev-1');
      await state.refresh();
      expect(state.deliveries, hasLength(1)); // 已知详情的不重复
      // 模拟其他设备产生的投递：只有 id 可从 sync 得知。
      server.deliveriesById['dlv-ext'] = {
        'id': 'dlv-ext',
        'item_id': 'item-ext',
        'source_device': 'dev-9',
        'target_device': 'dev-1',
        'status': 'waiting',
        'created_at': 1,
        'updated_at': 1,
      };
      server.recordChange('delivery', 'dlv-ext', 'upsert');
      await state.refresh();
      expect(state.observedDeliveryIds, contains('dlv-ext'));
    });

    test('renewItem 续期成功更新 expiresAt', () async {
      await state.sendText('续期');
      final item = state.items.single;
      final ok = await state.renewItem(item.id);
      expect(ok, isTrue);
      expect(state.items.single.expiresAt, 1000000 + 7 * 86400);
      expect(state.entryOp(item.id), OpStatus.success);
    });

    test('deleteItemById 成功移除条目；失败保留并报错', () async {
      await state.sendText('删除我');
      final item = state.items.single;
      final ok = await state.deleteItemById(item.id);
      expect(ok, isTrue);
      expect(state.items, isEmpty);

      await state.sendText('保留');
      final kept = state.items.single;
      server.itemsById.remove(kept.id); // 服务端已不存在 → 404
      final failed = await state.deleteItemById(kept.id);
      expect(failed, isFalse);
      expect(state.items.single.id, kept.id); // 原数据保留
      expect(state.entryOp(kept.id), OpStatus.error);
      expect(state.entryError(kept.id), isNotNull);
    });

    test('setPinned 切换图钉状态', () async {
      await state.sendText('置顶');
      final item = state.items.single;
      expect(item.pinned, isFalse);
      final ok = await state.setPinned(item.id, true);
      expect(ok, isTrue);
      expect(state.items.single.pinned, isTrue);
    });

    test('driveItems 排除定向传输，transferItems 只含定向', () async {
      await state.sendText('网盘内容');
      await state.sendText('定向内容', targetDevice: 'dev-1');
      expect(state.driveItems.map((i) => i.text), ['网盘内容']);
      expect(state.transferItems.map((i) => i.text), ['定向内容']);
    });

    test('loadUsage 拉取容量信息', () async {
      await state.loadUsage();
      expect(state.usageInfo?.totalBytes, 3072);
    });

    test('logout 撤销服务端 token 并清空本地状态', () async {
      await state.sendText('x');
      await state.logout();
      expect(state.isLoggedIn, isFalse);
      expect(state.items, isEmpty);
      expect(state.deliveries, isEmpty);
      expect(server.received.any((r) => r.uri.path == '/api/v1/auth/logout'),
          isTrue);
    });

    test('logout 服务端不可达时仍清空本地状态', () async {
      await server.stop();
      await state.logout();
      expect(state.isLoggedIn, isFalse);
      server = FakeV1Server();
      state.api.baseUrl = await server.start();
    });
  });
}
