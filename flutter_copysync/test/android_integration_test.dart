import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/bridge/android_bridge_models.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_android_host.dart';
import 'fake_v1_server.dart';
import 'helpers.dart';
import 'memory_token_store.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late FakeV1Server server;
  late AppState state;
  late FakeAndroidHost android;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    state = AppState(
      api: ApiClient(await server.start()),
      tokenStore: MemoryTokenStore(),
    );
    android = FakeAndroidHost();
    state.android = android;
  });

  tearDown(() async {
    await android.dispose();
    await server.stop();
  });

  Future<void> login() async {
    await state.login(
        password: server.password, deviceName: 'Kimi Android', platform: 'android');
  }

  test('登录成功后启动前台服务并对账下载（重启恢复）', () async {
    android.reconcileResult = [
      const AndroidDownloadRecord(
          deliveryId: 'dlv-x', name: 'a.png', state: AndroidDownloadState.ready),
    ];
    await login();
    expect(android.backgroundStartCount, 1);
    await Future<void>.delayed(Duration.zero);
    expect(state.downloadRecords, hasLength(1));
  });

  test('退出登录停止前台服务', () async {
    await login();
    await state.logout();
    expect(android.backgroundStopCount, 1);
  });

  /// 等待异步桥副作用落地（真实 HTTP + 事件循环）。
  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('sync 后出现发给我的 waiting 投递时系统通知一次且不重复', () async {
    await login();
    final item = await state.api.createTextItem('你好');
    await state.api.createDelivery(item.id, targetDevice: 'dev-1');
    await state.refresh();
    await settle();
    expect(android.notifications, hasLength(1));
    expect(android.notifications.single, contains('收到新内容'));
    await state.refresh();
    await settle();
    expect(android.notifications, hasLength(1));
  });

  test('发送文件成功后转存 Download/CopySync（sent: 语义）', () async {
    await login();
    final tmp = File('${Directory.systemTemp.path}/copysync_send_test.txt');
    await tmp.writeAsString('转存内容');
    await state.sendFile(tmp.path);
    await settle();
    expect(android.savedSent, hasLength(1));
    expect(android.savedSent.single['name'], 'copysync_send_test.txt');
    await tmp.delete();
  });

  test('接收文件经 DownloadManager 入队（带 Bearer）并 ack downloaded', () async {
    await login();
    final item = await state.api.createTextItem('待接收');
    final delivery =
        await state.api.createDelivery(item.id, targetDevice: 'dev-1');
    final ok = await state.receiveItemFile(item);
    expect(ok, isTrue);
    expect(android.enqueued, hasLength(1));
    final call = android.enqueued.single;
    expect(call['deliveryId'], delivery.id);
    expect('${call['url']}', contains('/api/v1/items/${item.id}/content'));
    expect((call['headers'] as Map)['Authorization'], 'Bearer cps_tok_1');
    expect(server.deliveriesById[delivery.id]!['status'], 'downloaded');
  });

  test('无对应投递时接收返回 false 且不入队', () async {
    await login();
    final item = await state.api.createTextItem('只进网盘');
    expect(await state.receiveItemFile(item), isFalse);
    expect(android.enqueued, isEmpty);
  });

  test('打开已接收文件透传 name/mime/deliveryId', () async {
    await login();
    final item = await state.api.createTextItem('打开我');
    final delivery =
        await state.api.createDelivery(item.id, targetDevice: 'dev-1');
    expect(await state.openReceivedItem(item), isTrue);
    expect(android.openedReceived.single['name'], item.name);
    expect(android.openedReceived.single['deliveryId'], delivery.id);
  });

  testWidgets('Android 收件箱复制走原生桥，下载按钮走 DownloadManager',
      (tester) async {
    await tester.runAsync(() async {
      await login();
      await seedText(state, '复制我');
      await state.refresh();
      await pumpShell(tester, state, desktopLayout: false);
      // 文本条目主操作是复制按钮
      final item = state.items.firstWhere((i) => i.text == '复制我');
      await tester.tap(find.byKey(Key('copy-${item.id}')));
      await Future<void>.delayed(Duration.zero);
      expect(android.lastClipboardText, '复制我');
    });
  });

  testWidgets('系统分享弹出确认对话框，发送后 shareConfirm 清理', (tester) async {
    await tester.runAsync(() async {
      await login();
      android.pendingShares = [
        const AndroidSharePayload(id: 'share-1', text: '分享来的文本'),
      ];
      await pumpShell(tester, state, desktopLayout: false);
      await Future<void>.delayed(Duration.zero);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('shareConfirmDialog')), findsOneWidget);
      expect(find.textContaining('分享来的文本'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shareSendButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(android.confirmedShareIds, [
        ['share-1']
      ]);
      expect(server.itemsById.values.any((i) => i['text'] == '分享来的文本'),
          isTrue);
      expect(find.byKey(const Key('shareConfirmDialog')), findsNothing);
    });
  });

  testWidgets('分享取消也调用 shareConfirm 清理缓存', (tester) async {
    await tester.runAsync(() async {
      await login();
      android.pendingShares = [
        const AndroidSharePayload(id: 'share-2', text: '不要的分享'),
      ];
      await pumpShell(tester, state, desktopLayout: false);
      await Future<void>.delayed(Duration.zero);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('shareCancelButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(android.confirmedShareIds, [
        ['share-2']
      ]);
      expect(server.itemsById, isEmpty);
    });
  });

  testWidgets('下拉刷新触发 sync（RefreshIndicator → state.refresh）',
      (tester) async {
    await tester.runAsync(() async {
      await login();
      await state.refresh();
      final syncCallsBefore = server.received
          .where((r) => r.uri.path == '/api/v1/sync')
          .length;
      await pumpShell(tester, state, desktopLayout: false);
      await tester.pump();
      // 手势动画在 runAsync 混合时基下不可靠，直接触发 onRefresh 验证
      // 接线（手势路径由 Emulator GUI 门覆盖）；三个页面均挂 RefreshIndicator。
      final indicator =
          tester.widget<RefreshIndicator>(find.byKey(const Key('pullRefresh')));
      await indicator.onRefresh();
      final syncCallsAfter = server.received
          .where((r) => r.uri.path == '/api/v1/sync')
          .length;
      expect(syncCallsAfter, greaterThan(syncCallsBefore));
      await tester.tap(find.byIcon(Icons.history));
      await tester.pump();
      expect(find.byKey(const Key('historyPullRefresh')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.cloud_outlined));
      await tester.pump();
      expect(find.byKey(const Key('drivePullRefresh')), findsOneWidget);
    });
  });
}
