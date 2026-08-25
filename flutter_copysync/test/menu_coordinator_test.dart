import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/bridge/bridge_models.dart';
import 'package:copysync/bridge/bridge_result.dart';
import 'package:copysync/state/history_controller.dart';
import 'package:copysync/state/menu_coordinator.dart';

import 'fake_bridge.dart';
import 'fake_v1_server.dart';
import 'helpers.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });
  late FakeBridge bridge;
  late HistoryController history;
  late MenuCoordinator menu;

  setUp(() {
    bridge = FakeBridge();
    history = HistoryController(bridge: bridge);
    menu = MenuCoordinator(bridge: bridge, history: history);
  });

  tearDown(() async {
    menu.dispose();
    history.dispose();
    await bridge.dispose();
  });

  test('start 注册主窗口与截图快捷键（历史快捷键由 HistoryController 注册）',
      () async {
    history.start();
    menu.start();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.registeredHotkeys,
        containsAll([BridgeHotkey.main, BridgeHotkey.history, BridgeHotkey.screenshot]));
  });

  test('hotkey.pressed(main) 切换主窗口', () async {
    menu.start();
    bridge.emit('hotkey.pressed', {'id': 'main'});
    await Future<void>.delayed(Duration.zero);
    expect(bridge.toggleMainWindowCount, 1);
  });

  test('hotkey.pressed(screenshot) 触发区域截图，成功进历史并更新状态', () async {
    bridge.screenshotResult = const BridgeResult.success(BridgeHistoryItem(
      id: 's1',
      kind: BridgeItemKind.image,
      text: '区域截图',
      fingerprint: 'fp-s1',
      created: 1,
    ));
    menu.start();
    bridge.emit('hotkey.pressed', {'id': 'screenshot'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(menu.statusMessage, contains('区域截图'));
  });

  test('截图用户取消不报错、状态不变', () async {
    menu.start();
    bridge.emit('hotkey.pressed', {'id': 'screenshot'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(menu.statusMessage, '等待复制');
  });

  test('menubar.action(openTransfers/openPreferences) 显示主窗口并切 tab',
      () async {
    final selected = <int>[];
    menu.onSelectTab = selected.add;
    menu.start();
    bridge.emit('menubar.action', {'action': 'openTransfers'});
    bridge.emit('menubar.action', {'action': 'openPreferences'});
    await Future<void>.delayed(Duration.zero);
    expect(selected, [1, 3]);
    expect(bridge.showMainWindowCount, 2);
  });

  test('menubar.action(toggleFooter) 切换底部状态栏可见性', () async {
    menu.start();
    expect(menu.footerVisible, isFalse);
    bridge.emit('menubar.action', {'action': 'toggleFooter'});
    await Future<void>.delayed(Duration.zero);
    expect(menu.footerVisible, isTrue);
    bridge.emit('menubar.action', {'action': 'toggleFooter'});
    await Future<void>.delayed(Duration.zero);
    expect(menu.footerVisible, isFalse);
  });

  test('clearHistory 无确认处理器时不执行（危险动作不得静默直执）', () async {
    bridge.historyItems.add(const BridgeHistoryItem(
        id: 'h1',
        kind: BridgeItemKind.text,
        text: 'x',
        fingerprint: 'f',
        created: 1));
    menu.start();
    bridge.emit('menubar.action', {'action': 'clearHistory'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.historyItems, isNotEmpty);
  });

  test('clearHistory 确认后清空历史并更新状态；取消不动', () async {
    bridge.historyItems.add(const BridgeHistoryItem(
        id: 'h1',
        kind: BridgeItemKind.text,
        text: 'x',
        fingerprint: 'f',
        created: 1));
    var confirms = 0;
    menu.confirmHandler = (title, message) async {
      confirms += 1;
      return confirms > 1; // 第一次取消，第二次确认
    };
    menu.start();
    bridge.emit('menubar.action', {'action': 'clearHistory'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.historyItems, isNotEmpty);
    bridge.emit('menubar.action', {'action': 'clearHistory'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.historyItems, isEmpty);
    expect(menu.statusMessage, contains('历史已清空'));
  });

  test('clearCache 确认后调用 cacheClear', () async {
    menu.confirmHandler = (title, message) async => true;
    menu.start();
    bridge.emit('menubar.action', {'action': 'clearCache'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.cacheClearCount, 1);
    expect(menu.statusMessage, contains('缓存已清理'));
  });

  test('checkUpdate 已最新时更新状态并回写菜单栏', () async {
    bridge.updateInfo = const UpdateInfo(
        current: '1.0.0', latest: '1.0.0', hasUpdate: false, url: '', sha256: '');
    menu.start();
    bridge.emit('menubar.action', {'action': 'checkUpdate'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(menu.statusMessage, contains('已经是最新版'));
    expect(bridge.setStatusMessages.last, contains('已经是最新版'));
  });

  test('checkUpdate 有新版时切到设置页', () async {
    final selected = <int>[];
    menu.onSelectTab = selected.add;
    menu.start();
    bridge.emit('menubar.action', {'action': 'checkUpdate'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(menu.statusMessage, contains('发现新版本 1.1.0'));
    expect(selected, [3]);
  });

  testWidgets('toggleFooter 显示底部状态栏，clearHistory 弹真实二次确认',
      (tester) async {
    await tester.runAsync(() async {
      final server = FakeV1Server();
      await server.start();
      final state = await loggedInState(server);
      await pumpShell(tester, state,
          bridge: bridge, history: history, menu: menu, desktopLayout: true);
      menu.start();
      expect(find.byKey(const Key('statusFooter')), findsNothing);
      bridge.emit('menubar.action', {'action': 'toggleFooter'});
      await Future<void>.delayed(Duration.zero); // 桥事件异步投递
      await tester.pump();
      expect(find.byKey(const Key('statusFooter')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('statusFooter')),
              matching: find.textContaining('台设备在线')),
          findsOneWidget);
      // 菜单栏清空历史 → 弹出确认对话框，确认后历史清空
      bridge.historyItems.add(const BridgeHistoryItem(
          id: 'h1',
          kind: BridgeItemKind.text,
          text: 'x',
          fingerprint: 'f',
          created: 1));
      bridge.emit('menubar.action', {'action': 'clearHistory'});
      await Future<void>.delayed(Duration.zero);
      await tester.pump();
      await tester.pump();
      expect(find.text('清空历史记录？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('menuConfirmButton')));
      await tester.pump();
      await Future<void>.delayed(Duration.zero);
      await tester.pump();
      expect(bridge.historyItems, isEmpty);
      expect(find.textContaining('历史已清空'), findsOneWidget);
      await server.stop();
    });
  });

  testWidgets('收到文件的下载走 files.saveReceived 且菜单可 Finder 定位',
      (tester) async {
    await tester.runAsync(() async {
      final server = FakeV1Server();
      await server.start();
      final state = await loggedInState(server);
      // 造一个文件条目，并把本机伪装成另一台设备（模拟收到的条目）。
      final path = '${Directory.systemTemp.path}/copysync_recv_test.bin';
      await File(path).writeAsBytes(List.filled(64, 66));
      await state.sendFile(path);
      state.device = null;
      state.restoredDeviceId = 'dev-other';
      await pumpShell(tester, state,
          bridge: bridge, history: history, menu: menu, desktopLayout: true);
      final item = state.items.firstWhere((i) => i.name.contains('recv_test'));
      // 桌面窗口下行内按钮可能被裁切，直接触发回调验证接线。
      tester
          .widget<IconButton>(find.byKey(Key('downloadButton-${item.id}')))
          .onPressed!();
      for (var i = 0; i < 100 && bridge.savedReceived.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pump();
      expect(bridge.savedReceived.single['name'], item.name);
      final moreFinder = find.byKey(Key('more-${item.id}'));
      // 命中测试在桌面壳内不稳定，直接点开菜单。
      await tester.tapAt(tester.getCenter(moreFinder));
      await tester.pump();
      await tester.pump();
      // 弹出菜单条目直接触发 onTap（覆盖接线逻辑）。
      tester
          .widget<PopupMenuItem<void>>(find.ancestor(
              of: find.text('在 Finder 中显示'),
              matching: find.byType(PopupMenuItem<void>)))
          .onTap!();
      await tester.pump();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.revealedReceived.single['name'], item.name);
      await File(path).delete();
      await server.stop();
    });
  });
}
