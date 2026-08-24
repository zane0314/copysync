import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/main.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
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

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(CopySyncApp(state: state));
    await tester.pump();
  }

  Future<void> loginThroughUi(WidgetTester tester) async {
    await tester.enterText(
        find.byKey(const Key('passwordField')), 'dev-pw-123');
    await tester.tap(find.byKey(const Key('loginButton')));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('登录页显示服务器/密码/设备名输入框与登录按钮', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      expect(find.byKey(const Key('serverField')), findsOneWidget);
      expect(find.byKey(const Key('passwordField')), findsOneWidget);
      expect(find.byKey(const Key('deviceField')), findsOneWidget);
      expect(find.byKey(const Key('loginButton')), findsOneWidget);
    });
  });

  testWidgets('密码错误显示服务端错误消息', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await tester.enterText(find.byKey(const Key('passwordField')), 'bad');
      await tester.tap(find.byKey(const Key('loginButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('密码错误'), findsOneWidget);
      expect(find.byKey(const Key('loginButton')), findsOneWidget); // 仍在登录页
    });
  });

  testWidgets('登录成功进入收件箱：标题、在线设备数、自动加载', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      expect(find.text('收件箱'), findsWidgets);
      expect(find.text('在线设备 1'), findsOneWidget);
    });
  });

  testWidgets('收件箱空态显示暂无内容', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      expect(find.text('暂无内容'), findsOneWidget);
    });
  });

  testWidgets('发送文本成功出现在列表，输入框被清空', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      await tester.enterText(
          find.byKey(const Key('pasteField')), 'V3 纵向闭环测试');
      await tester.tap(find.byKey(const Key('sendButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('V3 纵向闭环测试'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('pasteField')));
      expect(field.controller?.text, isEmpty);
    });
  });

  testWidgets('发送失败显示错误且保留输入内容', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      server.forceItemStatus = 500;
      await tester.enterText(find.byKey(const Key('pasteField')), '别丢我');
      await tester.tap(find.byKey(const Key('sendButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('服务器开小差了'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('pasteField')));
      expect(field.controller?.text, '别丢我'); // 失败保留原数据
    });
  });

  testWidgets('长文本在列表中以省略号截断', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      final longText = '很长' * 200;
      await tester.enterText(find.byKey(const Key('pasteField')), longText);
      await tester.tap(find.byKey(const Key('sendButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      final text = tester.widget<Text>(find.text(longText));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, isNotNull);
    });
  });

  testWidgets('刷新失败显示错误与重试按钮，原数据保留', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      await tester.enterText(find.byKey(const Key('pasteField')), '保留我');
      await tester.tap(find.byKey(const Key('sendButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('保留我'), findsOneWidget);

      await server.stop();
      await tester.tap(find.byKey(const Key('refreshButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byKey(const Key('retryButton')), findsOneWidget);
      expect(find.text('保留我'), findsOneWidget); // 原数据仍在
      // 恢复供 tearDown
      server = FakeV1Server();
      state.api.baseUrl = await server.start();
    });
  });

  testWidgets('Android 底栏四个 tab，非收件箱显示阶段 4 占位', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      expect(find.text('传输历史'), findsOneWidget);
      expect(find.text('临时网盘'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pump();
      expect(find.text('阶段 4 实现'), findsOneWidget);
    });
  });
}
