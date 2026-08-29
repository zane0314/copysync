import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/main.dart';
import 'package:copysync/state/app_state.dart';
import 'package:copysync/state/history_controller.dart';
import 'package:copysync/state/menu_coordinator.dart';

import 'fake_bridge.dart';
import 'fake_v1_server.dart';
import 'memory_token_store.dart';

/// 已登录的 AppState（直连 fake server，不经 UI）。
Future<AppState> loggedInState(FakeV1Server server) async {
  final state = AppState(
    api: ApiClient(server.baseUrl),
    tokenStore: MemoryTokenStore(),
  );
  await state.login(
      password: server.password, deviceName: 'Kimi Mac', platform: 'mac');
  return state;
}

/// 完整应用壳（含可选桥、历史浮窗控制器与菜单协调器）。
Widget testShell(
  AppState state, {
  FakeBridge? bridge,
  HistoryController? history,
  MenuCoordinator? menu,
  bool? desktopLayout,
}) {
  return CopySyncApp(
    state: state,
    bridge: bridge,
    updater: bridge,
    history: history,
    menu: menu,
    desktopLayout: desktopLayout,
  );
}

/// 泵出应用并等待异步落地。
Future<void> pumpShell(
  WidgetTester tester,
  AppState state, {
  FakeBridge? bridge,
  HistoryController? history,
  MenuCoordinator? menu,
  bool? desktopLayout,
}) async {
  await tester.pumpWidget(testShell(state,
      bridge: bridge,
      history: history,
      menu: menu,
      desktopLayout: desktopLayout));
  await tester.pump();
  await tester.pump();
}

/// 轮询等待异步操作落地，避免并发测试下固定延时过早断言。
Future<void> waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

/// 造一个文本 item 并刷新进列表。
Future<void> seedText(AppState state, String text,
    {String? targetDevice}) async {
  await state.sendText(text, targetDevice: targetDevice);
}
