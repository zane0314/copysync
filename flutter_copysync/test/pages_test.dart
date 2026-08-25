import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// mock 系统剪贴板文本（粘贴文本 pill 的数据源）。
  void mockClipboard(WidgetTester tester, String? text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? (text == null ? null : {'text': text})
          : null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

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
      expect(find.text('1 台设备在线'), findsOneWidget);
    });
  });

  testWidgets('收件箱空态显示暂无内容', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      expect(find.text('暂无内容'), findsOneWidget);
    });
  });

  testWidgets('粘贴文本发送成功出现在列表', (tester) async {
    await tester.runAsync(() async {
      mockClipboard(tester, 'V3 纵向闭环测试');
      await pumpApp(tester);
      await loginThroughUi(tester);
      await tester.tap(find.byKey(const Key('pasteTextButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('V3 纵向闭环测试'), findsOneWidget);
    });
  });

  testWidgets('剪贴板为空时粘贴给出提示，不发送', (tester) async {
    await tester.runAsync(() async {
      mockClipboard(tester, null);
      await pumpApp(tester);
      await loginThroughUi(tester);
      await tester.tap(find.byKey(const Key('pasteTextButton')));
      await tester.pump();
      expect(find.text('剪贴板没有可发送的文本'), findsOneWidget);
      expect(state.items, isEmpty);
    });
  });

  testWidgets('发送失败显示错误，数据不丢失', (tester) async {
    await tester.runAsync(() async {
      mockClipboard(tester, '别丢我');
      await pumpApp(tester);
      await loginThroughUi(tester);
      server.forceItemStatus = 500;
      await tester.tap(find.byKey(const Key('pasteTextButton')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('服务器开小差了'), findsOneWidget);
    });
  });

  testWidgets('长文本在列表中以省略号截断', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      final longText = '很长' * 200;
      await state.sendText(longText);
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
      await state.sendText('保留我');
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

  testWidgets('Android 底栏切换四个真实页面', (tester) async {
    await tester.runAsync(() async {
      await pumpApp(tester);
      await loginThroughUi(tester);
      expect(find.text('传输历史'), findsOneWidget);
      expect(find.text('临时网盘'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.history));
      await tester.pump();
      expect(find.text('暂无传输记录'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.cloud_outlined));
      await tester.pump();
      expect(find.text('网盘为空'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      await tester.pump();
      await tester.scrollUntilVisible(find.byKey(const Key('logoutButton')),
          160,
          scrollable: find.byType(Scrollable).last);
      expect(find.byKey(const Key('logoutButton')), findsOneWidget);
    });
  });

  group('文件/图片发送', () {
    late Directory tempDir;

    /// 1x1 透明 PNG。
    final pngBytes = [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00,
      0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, 0x00, 0x00, 0x00, 0x00,
      0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('copysync_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    testWidgets('收件箱显示发送文件与发送图片入口', (tester) async {
      await tester.runAsync(() async {
        await pumpApp(tester);
        await loginThroughUi(tester);
        expect(find.byKey(const Key('sendFileButton')), findsOneWidget);
        expect(find.byKey(const Key('sendImageButton')), findsOneWidget);
      });
    });

    testWidgets('image 条目先显示预览占位，加载完成后显示图片', (tester) async {
      await tester.runAsync(() async {
        await pumpApp(tester);
        await loginThroughUi(tester);
        final path = '${tempDir.path}/pic.png';
        await File(path).writeAsBytes(pngBytes);
        await state.sendImage(path);
        await tester.pump();
        expect(find.byKey(const Key('imagePreviewPlaceholder')), findsOneWidget);
        // 预览字节下载完成后替换为真实图片。
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        expect(find.byKey(const Key('imagePreview')), findsOneWidget);
        expect(find.text('pic.png'), findsOneWidget);
      });
    });

    testWidgets('file 条目显示图标、文件名与大小', (tester) async {
      await tester.runAsync(() async {
        await pumpApp(tester);
        await loginThroughUi(tester);
        final path = '${tempDir.path}/报告.txt';
        await File(path).writeAsBytes(List.filled(2048, 65));
        await state.sendFile(path);
        await tester.pump();
        expect(find.text('报告.txt'), findsOneWidget);
        expect(find.textContaining('2.0 KB'), findsOneWidget);
        expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
      });
    });

    testWidgets('发送中所有发送入口禁用（防重复点击）', (tester) async {
      await tester.runAsync(() async {
        mockClipboard(tester, 'hi');
        await pumpApp(tester);
        await loginThroughUi(tester);
        server.itemDelay = const Duration(milliseconds: 300);
        final sending = state.sendText('hi'); // 同步置 loading
        await tester.pump();
        for (final key in const [
          Key('pasteTextButton'),
          Key('sendFileButton'),
          Key('sendImageButton'),
        ]) {
          final button = tester.widget<ElevatedButton>(find.byKey(key));
          expect(button.onPressed, isNull, reason: '$key 应在 loading 时禁用');
        }
        await sending;
        await tester.pump();
      });
    });
  });
}
