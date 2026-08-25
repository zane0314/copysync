import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
import 'helpers.dart';

class _RealHttpOverrides extends HttpOverrides {}

/// 布局断言（主设计 §11：可点击元素在可视区内且边界不相交）。
/// 桌面 1536x1024（参考图尺寸）与手机 390x844 两种尺寸分别验证四页。
void main() {
  late FakeV1Server server;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    await server.start();
  });

  tearDown(() => server.stop());

  /// 收集可见的顶层可点击元素（排除按钮内部的实现细节，如
  /// PopupMenuButton 内置的 IconButton）。
  List<Rect> actionableRects(WidgetTester tester) {
    final rects = <Rect>[];
    void collect(Finder finder) {
      for (final element in finder.evaluate()) {
        if (element.findAncestorWidgetOfExactType<PopupMenuButton<void>>() !=
                null &&
            element.widget is IconButton) {
          continue; // PopupMenuButton 内部按钮与父级同区域
        }
        final renderObject = element.renderObject;
        if (renderObject is! RenderBox || !renderObject.hasSize) continue;
        final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
        if (rect.isEmpty) continue;
        rects.add(rect);
      }
    }

    collect(find.byType(ElevatedButton));
    collect(find.byType(OutlinedButton));
    collect(find.byType(TextButton));
    collect(find.byType(IconButton));
    collect(find.byType(PopupMenuButton<void>));
    return rects;
  }

  void assertLayout(WidgetTester tester, Size viewport) {
    final rects = actionableRects(tester);
    expect(rects, isNotEmpty, reason: '页面应至少有一个可点击元素');
    final screen = Offset.zero & viewport;
    for (final rect in rects) {
      expect(screen.contains(rect.center), isTrue,
          reason: '可点击元素中心应在可视区内：$rect');
      expect(rect.overlaps(screen), isTrue,
          reason: '可点击元素应在可视区内：$rect');
    }
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final overlap = rects[i].intersect(rects[j]);
        expect(overlap.isEmpty, isTrue,
            reason: '可点击元素边界不应相交：${rects[i]} × ${rects[j]}');
      }
    }
  }

  Future<AppState> seededState() async {
    final state = await loggedInState(server);
    await state.sendText('会议纪要：周一上午十点项目同步会');
    await state.sendText('很长' * 200);
    return state;
  }

  for (final (name, size, desktop) in [
    ('桌面 1536x1024', const Size(1536, 1024), true),
    ('手机 390x844', const Size(390, 844), false),
  ]) {
    testWidgets('布局断言：$name 四页可点击元素在可视区内且不相交', (tester) async {
      final state = (await tester.runAsync(seededState))!;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpShell(tester, state, desktopLayout: desktop);
      assertLayout(tester, size);
      for (final tab in ['传输历史', '临时网盘', '设置']) {
        await tester.tap(find.text(tab).first);
        await tester.pump();
        await tester.pump();
        assertLayout(tester, size);
      }
    });
  }
}
