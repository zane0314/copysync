import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/bridge/bridge_models.dart';
import 'package:copysync/state/app_state.dart';
import 'package:copysync/state/history_controller.dart';

import 'fake_bridge.dart';
import 'fake_v1_server.dart';
import 'helpers.dart';
import 'memory_token_store.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late FakeV1Server server;
  late AppState state;
  late FakeBridge bridge;
  late HistoryController history;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    state = AppState(
      api: ApiClient(await server.start()),
      tokenStore: MemoryTokenStore(),
    );
    await state.login(
        password: server.password, deviceName: 'Kimi Mac', platform: 'mac');
    bridge = FakeBridge();
    bridge.historyItems = [
      const BridgeHistoryItem(
          id: 'h-1',
          kind: BridgeItemKind.text,
          text: '第一段文本',
          fingerprint: 'a',
          created: 1),
      const BridgeHistoryItem(
          id: 'h-2',
          kind: BridgeItemKind.text,
          text: '第二段内容',
          fingerprint: 'b',
          created: 2),
    ];
    history = HistoryController(bridge: bridge);
  });

  tearDown(() async {
    history.dispose();
    await bridge.dispose();
    await server.stop();
  });

  Future<void> pumpWithHistory(WidgetTester tester) async {
    await pumpShell(tester, state,
        bridge: bridge, history: history, desktopLayout: true);
  }

  testWidgets('start 注册历史快捷键并启动剪贴板监听', (tester) async {
    await tester.runAsync(() async {
      history.start();
      expect(bridge.registeredHotkey, BridgeHotkey.history);
      expect(bridge.watchStartCount, 1);
    });
  });

  testWidgets('hotkey.pressed(history) 事件弹出历史浮窗，Esc 关闭', (tester) async {
    await tester.runAsync(() async {
      history.start();
      await pumpWithHistory(tester);
      expect(find.byKey(const Key('historyPopup')), findsNothing);
      bridge.emit('hotkey.pressed', {'id': 'history'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('historyPopup')), findsOneWidget);
      expect(find.text('第一段文本'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('historyPopup')), findsNothing);
    });
  });

  testWidgets('menubar.action(toggleHistory) 同样弹出浮窗', (tester) async {
    await tester.runAsync(() async {
      history.start();
      await pumpWithHistory(tester);
      bridge.emit('menubar.action', {'action': 'toggleHistory'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('historyPopup')), findsOneWidget);
    });
  });

  testWidgets('输入即搜索，方向键选择，回车粘贴到前一应用', (tester) async {
    await tester.runAsync(() async {
      history.start();
      await pumpWithHistory(tester);
      bridge.emit('hotkey.pressed', {'id': 'history'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('historySearch')), '第二');
      await tester.pump();
      expect(find.text('第一段文本'), findsNothing);
      expect(find.text('第二段内容'), findsOneWidget);
      // 方向键移动选中（仅一条结果时保持 0）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(history.selectedIndex, 0);
      // 回车粘贴。
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bridge.lastCopiedHistoryId, 'h-2');
      expect(bridge.lastPasteText, '第二段内容');
      expect(find.byKey(const Key('historyPopup')), findsNothing); // 粘贴后关闭
    });
  });

  testWidgets('方向键在多条历史间移动选择', (tester) async {
    await tester.runAsync(() async {
      history.start();
      await pumpWithHistory(tester);
      bridge.emit('hotkey.pressed', {'id': 'history'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      expect(history.selectedIndex, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(history.selectedIndex, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(history.selectedIndex, 0);
    });
  });

  testWidgets('clipboard.changed 带条目 payload：仅同步列表不重复写入',
      (tester) async {
    await tester.runAsync(() async {
      history.start();
      await pumpWithHistory(tester);
      bridge.emit('clipboard.changed', {
        'id': 'h-9',
        'kind': 'text',
        'text': '新复制',
        'fingerprint': 'c',
        'created': 9,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(history.items.first.text, '新复制');
      expect(bridge.historyAddTextCount, 0); // 原生侧已写入，Dart 不重复
    });
  });

  testWidgets('clipboard.changed 无 payload：读剪贴板写入历史', (tester) async {
    await tester.runAsync(() async {
      history.start();
      bridge.clipboardText = '回退写入';
      await pumpWithHistory(tester);
      bridge.emit('clipboard.changed');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bridge.historyAddTextCount, 1);
      expect(history.items.first.text, '回退写入');
    });
  });

  testWidgets('悬浮固定开关写入桥', (tester) async {
    await tester.runAsync(() async {
      history.start();
      await pumpWithHistory(tester);
      bridge.emit('hotkey.pressed', {'id': 'history'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      expect(history.pinned, isFalse);
      await tester.tap(find.byKey(const Key('historyPinButton')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(bridge.pinned, isTrue);
      expect(history.pinned, isTrue);
    });
  });
}
