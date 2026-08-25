import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
import 'helpers.dart';
import 'memory_token_store.dart';

/// flutter_test 会把 HttpClient 替换为恒 400 的 mock；
/// 基类 HttpOverrides.createHttpClient 的默认实现会创建真实 client，用它绕回真实网络。
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late FakeV1Server server;
  late AppState state;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    state = AppState(
      api: ApiClient(await server.start()),
      tokenStore: MemoryTokenStore(),
    );
  });

  tearDown(() => server.stop());

  testWidgets('空态显示暂无传输记录', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state);
      await tester.tap(find.byIcon(Icons.history));
      await tester.pump();
      expect(find.text('暂无传输记录'), findsOneWidget);
    });
  });

  testWidgets('定向条目显示方向与状态，确认收到走 ack', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('定向文本', targetDevice: 'dev-1');
      await state.sendToDevice(state.items.single.id, 'dev-1');
      await pumpShell(tester, state);
      await tester.tap(find.byIcon(Icons.history));
      await tester.pump();
      expect(find.text('定向文本'), findsOneWidget);
      expect(find.textContaining('发出'), findsWidgets);
      expect(find.textContaining('等待接收'), findsOneWidget);
      final ack = find.byKey(Key('ack-${state.deliveries.single.id}'));
      expect(ack, findsOneWidget);
      await tester.tap(ack);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('已确认'), findsOneWidget);
    });
  });

  testWidgets('ack 失败显示原因且条目保留', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('定向文本', targetDevice: 'dev-1');
      await state.sendToDevice(state.items.single.id, 'dev-1');
      final delivery = state.deliveries.single;
      server.deliveriesById[delivery.id]!['target_device'] = 'dev-9'; // 变成非本机投递
      await pumpShell(tester, state);
      await tester.tap(find.byIcon(Icons.history));
      await tester.pump();
      await tester.tap(find.byKey(Key('ack-${delivery.id}')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('只能由目标设备确认'), findsOneWidget);
      expect(find.text('定向文本'), findsOneWidget);
    });
  });

  testWidgets('sync 中未知详情的投递显示占位行并可尝试确认', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
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
      await pumpShell(tester, state);
      await tester.tap(find.byIcon(Icons.history));
      await tester.pump();
      expect(find.textContaining('dlv-ext'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ack-dlv-ext')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(server.deliveriesById['dlv-ext']!['status'], 'delivered');
    });
  });
}
