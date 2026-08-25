import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_bridge.dart';
import 'fake_v1_server.dart';
import 'helpers.dart';
import 'memory_token_store.dart';

class _RealHttpOverrides extends HttpOverrides {}

/// golden 初稿：macOS 桌面尺寸（1280x800），四页各一张。
/// 字体为测试默认 Ahem（方块字形），验证布局结构而非字体渲染。
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

  Future<void> pumpMac(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpShell(tester, state, bridge: bridge, desktopLayout: true);
    await tester.pump();
  }

  testWidgets('golden: 四页 macOS 布局', (tester) async {
    // 数据准备需要真实 HTTP（runAsync）；matchesGoldenFile 内部也用
    // runAsync，不能嵌套，故渲染与截图在正常测试体进行。
    await tester.runAsync(() async {
      state = await loggedInState(server);
      await state.sendText('圣何塞-1（500G CN2）trojan://d3261831-f49');
      await state.sendText('定向文本', targetDevice: 'dev-1');
      await state.sendToDevice(
          state.items.firstWhere((i) => i.text == '定向文本').id, 'dev-1');
      await state.refresh();
    });
    await pumpMac(tester);

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/inbox_macos.png'));

    await tester.tap(find.text('传输历史').first);
    await tester.pump();
    await tester.pump();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/history_macos.png'));

    await tester.tap(find.text('临时网盘').first);
    await tester.pump();
    await tester.pump();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/drive_macos.png'));

    await tester.tap(find.text('设置').first);
    await tester.pump();
    await tester.pump();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_macos.png'));
  });
}
