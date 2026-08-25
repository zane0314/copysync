import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/bridge/bridge_result.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_bridge.dart';
import 'fake_v1_server.dart';
import 'helpers.dart';
import 'memory_token_store.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late FakeV1Server server;
  late AppState state;
  late FakeBridge bridge;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    state = AppState(
      api: ApiClient(await server.start()),
      tokenStore: MemoryTokenStore(),
    );
    bridge = FakeBridge();
  });

  tearDown(() async {
    await bridge.dispose();
    await server.stop();
  });

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pump();
    await tester.pump();
  }

  /// 设置页为 ListView，靠后的区块需滚动到可视区再点击。
  Future<void> scrollToKey(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(find.byKey(key), 160,
        scrollable: find.byType(Scrollable).last);
    await tester.pump();
  }

  testWidgets('设备列表显示名称平台与在线状态', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.refresh();
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      expect(find.textContaining('Kimi Mac'), findsOneWidget);
      expect(find.textContaining('在线'), findsWidgets);
    });
  });

  testWidgets('桥不可用时登录启动/缓存/更新显示明确降级提示', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state); // 不传 bridge/updater
      await openSettings(tester);
      expect(find.text('当前平台不支持登录启动设置'), findsOneWidget);
      expect(find.text('当前平台不支持缓存清理'), findsOneWidget);
      expect(find.text('当前平台不支持检查更新'), findsOneWidget);
    });
  });

  testWidgets('登录启动开关读取并写入桥', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      bridge.loginItemEnabled = false;
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      final sw = tester.widget<Switch>(find.descendant(
          of: find.byKey(const Key('loginItemSwitch')),
          matching: find.byType(Switch)));
      expect(sw.value, isFalse);
      await tester.tap(find.byKey(const Key('loginItemSwitch')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bridge.loginItemEnabled, isTrue);
    });
  });

  testWidgets('清理缓存调用桥并显示结果', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      expect(find.textContaining('缓存'), findsWidgets);
      await tester.tap(find.byKey(const Key('clearCacheButton')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bridge.cacheClearCount, 1);
      expect(find.textContaining('已清理'), findsOneWidget);
    });
  });

  testWidgets('检查更新显示新版本与安装入口', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      await tester.tap(find.byKey(const Key('checkUpdateButton')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.textContaining('发现新版本 1.1.0'), findsOneWidget);
      await tester.tap(find.byKey(const Key('installUpdateButton')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bridge.installedUpdatePath, '/tmp/app.zip');
    });
  });

  testWidgets('检查更新失败显示原因不冒充成功', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      bridge.failWith = <T>() => const BridgeResult.failure(
          errorCode: 'system_error', errorMessage: '网络不可达');
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      await tester.tap(find.byKey(const Key('checkUpdateButton')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.textContaining('网络不可达'), findsOneWidget);
    });
  });

  testWidgets('退出登录回到登录页', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      await scrollToKey(tester, const Key('logoutButton'));
      await tester.tap(find.byKey(const Key('logoutButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byKey(const Key('loginButton')), findsOneWidget);
    });
  });

  testWidgets('修改密码成功后全设备下线回到登录页', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      await scrollToKey(tester, const Key('changePasswordButton'));
      await tester.tap(find.byKey(const Key('changePasswordButton')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('currentPasswordField')), 'dev-pw-123');
      await tester.enterText(
          find.byKey(const Key('newPasswordField')), 'new-password-456');
      await tester.tap(find.byKey(const Key('confirmPasswordButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(server.password, 'new-password-456');
      expect(find.byKey(const Key('loginButton')), findsOneWidget);
    });
  });

  testWidgets('修改密码当前密码错误显示原因且保持登录', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      await scrollToKey(tester, const Key('changePasswordButton'));
      await tester.tap(find.byKey(const Key('changePasswordButton')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('currentPasswordField')), 'wrong-password');
      await tester.enterText(
          find.byKey(const Key('newPasswordField')), 'new-password-456');
      await tester.tap(find.byKey(const Key('confirmPasswordButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(server.password, 'dev-pw-123');
      expect(state.isLoggedIn, isTrue);
      expect(find.textContaining('当前密码错误'), findsOneWidget);
    });
  });

  testWidgets('彻底清空需二次确认且确认后列表清空', (tester) async {
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('待清空内容');
      await pumpShell(tester, state, bridge: bridge);
      await openSettings(tester);
      // 第一次确认后、第二次取消：内容不动
      await scrollToKey(tester, const Key('clearAllButton'));
      await tester.tap(find.byKey(const Key('clearAllButton')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('clearAllConfirm1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('clearAllCancel2')));
      await tester.pump();
      expect(server.itemsById, isNotEmpty);
      // 两次都确认：清空
      await scrollToKey(tester, const Key('clearAllButton'));
      await tester.tap(find.byKey(const Key('clearAllButton')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('clearAllConfirm1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('clearAllConfirm2')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(server.itemsById, isEmpty);
      expect(state.items, isEmpty);
      expect(find.textContaining('已清空'), findsOneWidget);
    });
  });
}
