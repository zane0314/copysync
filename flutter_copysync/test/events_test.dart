import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:copysync/api/api_client.dart';
import 'package:copysync/state/app_state.dart';

import 'fake_v1_server.dart';
import 'memory_token_store.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late FakeV1Server server;
  late AppState state;
  var stateDisposed = false;

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  setUp(() async {
    server = FakeV1Server();
    stateDisposed = false;
    state = AppState(
      api: ApiClient(await server.start()),
      tokenStore: MemoryTokenStore(),
    );
  });

  tearDown(() async {
    if (!stateDisposed) state.dispose();
    await server.stop();
  });

  Future<bool> eventually(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return condition();
  }

  Future<void> login() => state.login(
    password: server.password,
    deviceName: 'Events Mac',
    platform: 'mac',
  );

  test('SSE sync 事件只触发现有增量 refresh，并更新列表', () async {
    server.eventsToCloseAfterInitial = 1;
    await login();
    state.startRealtimeSync();
    expect(await eventually(() => server.eventConnectionCount == 1), isTrue);
    expect(
      await eventually(() => state.refreshStatus == OpStatus.success),
      isTrue,
    );
    expect(
      await eventually(
        () => server.eventConnectionCount >= 2,
        timeout: const Duration(seconds: 4),
      ),
      isTrue,
    );
    server.addExternalText('来自事件');
    await server.emitEvent();
    expect(
      await eventually(() => state.items.any((item) => item.text == '来自事件')),
      isTrue,
    );
    final cursors = server.received
        .where((request) => request.uri.path == '/api/v1/sync')
        .map((request) => request.uri.queryParameters['cursor'])
        .toList();
    expect(cursors, contains('1'));
  });

  test('SSE 断线按间隔重连，注销后取消重连请求', () async {
    server.eventsToCloseAfterInitial = 1;
    await login();
    state.startRealtimeSync();
    expect(await eventually(() => server.eventConnectionCount == 1), isTrue);
    expect(
      await eventually(
        () => server.eventConnectionCount >= 2,
        timeout: const Duration(seconds: 4),
      ),
      isTrue,
    );
    final connectionsAfterReconnect = server.eventConnectionCount;
    await state.logout();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(server.eventConnectionCount, connectionsAfterReconnect);
  });

  test('dispose 后 SSE 不再请求也不通知监听器', () async {
    await login();
    state.startRealtimeSync();
    expect(await eventually(() => server.eventConnectionCount == 1), isTrue);
    var notifications = 0;
    state.addListener(() => notifications += 1);
    state.dispose();
    stateDisposed = true;
    final before = notifications;
    server.addExternalText('dispose 后的事件');
    await server.emitEvent();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notifications, before);
    expect(server.eventConnectionCount, 1);
  });
}
