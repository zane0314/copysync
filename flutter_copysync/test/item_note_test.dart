import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
import 'helpers.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late FakeV1Server server;
  late AppState state;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    await server.start();
    state = await loggedInState(server);
    await state.sendText('可编辑备注');
  });

  tearDown(() => server.stop());

  Future<void> openDrive(WidgetTester tester) async {
    await pumpShell(tester, state);
    await tester.tap(find.byIcon(Icons.cloud_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> openNoteEditor(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(Key('more-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备注'));
    await tester.pumpAndSettle();
  }

  testWidgets('列表项备注入口可保存并显示进行中与成功反馈', (tester) async {
    await tester.runAsync(() async {
      final id = state.items.single.id;
      await openDrive(tester);
      await openNoteEditor(tester, id);
      expect(find.byKey(Key('noteDialog-$id')), findsOneWidget);
      await tester.enterText(find.byKey(Key('noteField-$id')), '重要内容');
      server.patchDelay = const Duration(milliseconds: 200);
      await tester.tap(find.byKey(Key('saveNote-$id')));
      await tester.pump();
      expect(find.text('保存中…'), findsOneWidget);
      await waitUntil(tester, () => state.items.single.note == '重要内容');
      expect(server.itemsById[id]?['note'], '重要内容');
      expect(find.text('备注已保存'), findsOneWidget);
    });
  });

  testWidgets('备注保存失败显示原因且保留原备注，可重试', (tester) async {
    await tester.runAsync(() async {
      final id = state.items.single.id;
      await openDrive(tester);
      await openNoteEditor(tester, id);
      await tester.enterText(find.byKey(Key('noteField-$id')), '不会保存');
      server.forcePatchStatus = 500;
      server.forcePatchCode = 'server_error';
      server.forcePatchMessage = '服务端拒绝备注';
      await tester.tap(find.byKey(Key('saveNote-$id')));
      await waitUntil(tester, () => state.entryOp(id) == OpStatus.error);
      expect(find.byKey(Key('noteError-$id')), findsOneWidget);
      expect(state.items.single.note, isEmpty);
      server.forcePatchStatus = null;
      await tester.tap(find.byKey(Key('saveNote-$id')));
      await waitUntil(tester, () => state.items.single.note == '不会保存');
      expect(find.text('备注已保存'), findsOneWidget);
    });
  });
}
