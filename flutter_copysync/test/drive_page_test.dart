import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
import 'helpers.dart';
import 'memory_token_store.dart';

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

  Future<void> openDrive(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.cloud_outlined));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }

  /// 打开条目更多菜单（菜单弹出与 onTap 回调各需一帧）。
  Future<void> tapMenu(WidgetTester tester, String itemId, String label) async {
    await tester.tap(find.byKey(Key('more-$itemId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// 轮询等待异步操作落地（套件并发跑时固定延时不可靠）。
  Future<void> waitUntil(WidgetTester tester, bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  }

  testWidgets('空态显示网盘为空与容量信息', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state);
      await openDrive(tester);
      expect(find.text('网盘为空'), findsOneWidget);
      expect(find.textContaining('已用'), findsOneWidget);
    });
  });

  testWidgets('定向条目不进入网盘列表', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('网盘内容');
      await state.sendText('定向内容', targetDevice: 'dev-1');
      await pumpShell(tester, state);
      await openDrive(tester);
      expect(find.text('网盘内容'), findsOneWidget);
      expect(find.text('定向内容'), findsNothing);
    });
  });

  testWidgets('删除需二次确认：取消保留，确认后移除', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('将删除');
      await pumpShell(tester, state);
      await openDrive(tester);
      final id = state.items.single.id;
      await tapMenu(tester, id, '删除');
      // 二次确认弹窗
      expect(find.byKey(const Key('confirmDeleteButton')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('将删除'), findsOneWidget);
      expect(server.itemsById, isNotEmpty);

      await tapMenu(tester, id, '删除');
      await tester.tap(find.byKey(const Key('confirmDeleteButton')));
      await waitUntil(tester, () => server.itemsById.isEmpty);
      expect(find.text('将删除'), findsNothing);
      expect(server.itemsById, isEmpty);
      expect(find.text('网盘为空'), findsOneWidget);
    });
  });

  testWidgets('续期成功更新到期状态', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('续期我');
      await pumpShell(tester, state);
      await openDrive(tester);
      await tapMenu(tester, state.items.single.id, '续期 7 天');
      await waitUntil(
          tester, () => state.items.single.expiresAt == 1000000 + 7 * 86400);
      expect(state.items.single.expiresAt, 1000000 + 7 * 86400);
    });
  });

  testWidgets('图钉切换显示永久标记', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('置顶我');
      await pumpShell(tester, state);
      await openDrive(tester);
      await tapMenu(tester, state.items.single.id, '图钉置顶');
      await waitUntil(tester, () => state.items.single.pinned);
      expect(state.items.single.pinned, isTrue);
      expect(find.textContaining('永久'), findsOneWidget);
    });
  });

  testWidgets('长文本省略显示，点击标题弹出完整内容', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      final longText = '很长' * 200;
      await state.sendText(longText);
      await pumpShell(tester, state);
      await openDrive(tester);
      final title = tester.widget<Text>(find.text(longText));
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.maxLines, isNotNull);
      await tester.tap(find.text(longText));
      await tester.pump();
      expect(find.byKey(const Key('itemDetailDialog')), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pump();
    });
  });
}
