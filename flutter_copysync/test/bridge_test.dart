import 'dart:convert';

import 'package:copysync/bridge/bridge_models.dart';
import 'package:copysync/bridge/bridge_result.dart';
import 'package:copysync/bridge/macos_native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用 mock MethodChannel 验证 macOS 桥接：成功路径解析 +
/// 权限拒绝/用户取消/系统错误/桥缺失 全部映射为 BridgeResult，禁止静默失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('xyz.copysync/bridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall) handler;

  setUp(() {
    calls = [];
    handler = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final result = handler(call);
      if (result is Exception) throw result;
      return result;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  MethodCall lastCall() => calls.last;

  PlatformException denied([String message = '需要权限']) =>
      PlatformException(code: 'permission_denied', message: message);
  PlatformException cancelled() =>
      PlatformException(code: 'cancelled', message: '用户已取消');
  PlatformException systemError() =>
      PlatformException(code: 'system_error', message: '系统错误');

  group('BridgeResult', () {
    test('success 携带 value，failure 携带 errorCode/errorMessage', () {
      const ok = BridgeResult.success(42);
      expect(ok.ok, isTrue);
      expect(ok.value, 42);
      expect(ok.errorCode, isNull);
      const bad =
          BridgeResult<void>.failure(errorCode: 'cancelled', errorMessage: 'x');
      expect(bad.ok, isFalse);
      expect(bad.errorCode, 'cancelled');
      expect(bad.errorMessage, 'x');
    });
  });

  group('menubar', () {
    test('setStatus 透传 ok/message，成功返回 ok', () async {
      final bridge = MacosNativeBridge();
      final result =
          await bridge.menubarSetStatus(ok: false, message: '复制失败');
      expect(result.ok, isTrue);
      expect(lastCall().method, 'menubar.setStatus');
      expect(lastCall().arguments, {'ok': false, 'message': '复制失败'});
    });

    test('showMainWindow/toggleMainWindow 命中对应方法名', () async {
      final bridge = MacosNativeBridge();
      await bridge.menubarShowMainWindow();
      expect(lastCall().method, 'menubar.showMainWindow');
      await bridge.menubarToggleMainWindow();
      expect(lastCall().method, 'menubar.toggleMainWindow');
    });

    test('系统错误映射为 failure，不静默', () async {
      handler = (_) => systemError();
      final bridge = MacosNativeBridge();
      final result = await bridge.menubarShowMainWindow();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'system_error');
      expect(result.errorMessage, '系统错误');
    });
  });

  group('hotkey', () {
    test('register main 不传 shortcut', () async {
      final bridge = MacosNativeBridge();
      final result = await bridge.hotkeyRegister(BridgeHotkey.main);
      expect(result.ok, isTrue);
      expect(lastCall().method, 'hotkey.register');
      expect(lastCall().arguments, {'id': 'main'});
    });

    test('register history 携带 shortcut 选项', () async {
      final bridge = MacosNativeBridge();
      await bridge.hotkeyRegister(BridgeHotkey.history,
          shortcut: HistoryShortcut.commandShift);
      expect(lastCall().arguments,
          {'id': 'history', 'shortcut': 'commandShift'});
    });

    test('注册失败映射 hotkey_failed', () async {
      handler = (_) =>
          PlatformException(code: 'hotkey_failed', message: '全局快捷键注册失败（1）');
      final bridge = MacosNativeBridge();
      final result = await bridge.hotkeyRegister(BridgeHotkey.screenshot);
      expect(result.ok, isFalse);
      expect(result.errorCode, 'hotkey_failed');
    });

    test('unregister 命中方法名', () async {
      final bridge = MacosNativeBridge();
      await bridge.hotkeyUnregister(BridgeHotkey.main);
      expect(lastCall().method, 'hotkey.unregister');
      expect(lastCall().arguments, {'id': 'main'});
    });
  });

  group('clipboard', () {
    test('watch/stop 启动与停止监听', () async {
      handler = (call) => call.method == 'clipboard.watch' ? true : null;
      final bridge = MacosNativeBridge();
      final started = await bridge.clipboardWatchStart();
      expect(started.ok, isTrue);
      expect(started.value, isTrue);
      expect(lastCall().method, 'clipboard.watch');
      await bridge.clipboardWatchStop();
      expect(lastCall().method, 'clipboard.stop');
    });

    test('readText 返回字符串，空剪贴板返回 null', () async {
      handler = (_) => '你好';
      final bridge = MacosNativeBridge();
      expect((await bridge.clipboardReadText()).value, '你好');
      expect(lastCall().method, 'clipboard.readText');
      handler = (_) => null;
      expect((await bridge.clipboardReadText()).value, isNull);
    });

    test('readImage 返回 base64 解码后的 PNG 字节', () async {
      final png = Uint8List.fromList([1, 2, 3]);
      handler = (_) => base64Encode(png);
      final bridge = MacosNativeBridge();
      final result = await bridge.clipboardReadImage();
      expect(result.ok, isTrue);
      expect(result.value, png);
      expect(lastCall().method, 'clipboard.readImage');
    });

    test('write 文本默认带 ignoreNext=false，图片走 dataBase64', () async {
      final bridge = MacosNativeBridge();
      await bridge.clipboardWrite(text: 'abc');
      expect(lastCall().method, 'clipboard.write');
      expect(lastCall().arguments,
          {'kind': 'text', 'text': 'abc', 'ignoreNext': false});
      final png = Uint8List.fromList([9]);
      await bridge.clipboardWrite(png: png, ignoreNext: true);
      expect(lastCall().arguments, {
        'kind': 'image',
        'dataBase64': base64Encode(png),
        'ignoreNext': true,
      });
    });

    test('write 无内容映射 invalid_args（Dart 侧先校验，不发通道）', () async {
      final bridge = MacosNativeBridge();
      final result = await bridge.clipboardWrite();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_args');
      expect(calls, isEmpty);
    });

    test('ignoreNext 命中 clipboard.ignoreNext', () async {
      final bridge = MacosNativeBridge();
      await bridge.clipboardIgnoreNext();
      expect(lastCall().method, 'clipboard.ignoreNext');
    });

    test('写入失败映射 system_error', () async {
      handler = (_) => systemError();
      final bridge = MacosNativeBridge();
      final result = await bridge.clipboardWrite(text: 'x');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'system_error');
    });
  });

  group('screenshot', () {
    final itemMap = {
      'id': 'uuid-1',
      'kind': 'image',
      'text': '区域截图',
      'path': '/tmp/a.png',
      'fingerprint': 'ff',
      'created': 1700000000.0,
    };

    test('captureRegion 成功解析历史条目', () async {
      handler = (_) => itemMap;
      final bridge = MacosNativeBridge();
      final result = await bridge.screenshotCaptureRegion();
      expect(result.ok, isTrue);
      expect(result.value!.id, 'uuid-1');
      expect(result.value!.kind, BridgeItemKind.image);
      expect(result.value!.path, '/tmp/a.png');
      expect(lastCall().method, 'screenshot.captureRegion');
    });

    test('无屏幕录制权限映射 permission_denied', () async {
      handler = (_) => denied('屏幕录制权限未开启');
      final bridge = MacosNativeBridge();
      final result = await bridge.screenshotCaptureRegion();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'permission_denied');
    });

    test('用户取消框选映射 cancelled', () async {
      handler = (_) => cancelled();
      final bridge = MacosNativeBridge();
      final result = await bridge.screenshotCaptureRegion();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'cancelled');
    });
  });

  group('paste', () {
    test('intoPreviousApp 透传文本内容', () async {
      final bridge = MacosNativeBridge();
      final result = await bridge.pasteIntoPreviousApp(text: 'hi');
      expect(result.ok, isTrue);
      expect(lastCall().method, 'paste.intoPreviousApp');
      expect(lastCall().arguments, {'kind': 'text', 'text': 'hi'});
    });

    test('无辅助功能权限映射 permission_denied', () async {
      handler = (_) => denied('允许辅助功能后再粘贴');
      final bridge = MacosNativeBridge();
      final result = await bridge.pasteIntoPreviousApp(text: 'hi');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'permission_denied');
    });

    test('找不到前一应用映射 not_found', () async {
      handler = (_) =>
          PlatformException(code: 'not_found', message: '没有可粘贴的目标应用');
      final bridge = MacosNativeBridge();
      final result = await bridge.pasteIntoPreviousApp(text: 'hi');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'not_found');
    });
  });

  group('history', () {
    final textItem = {
      'id': 't1',
      'kind': 'text',
      'text': '条目',
      'fingerprint': 'aa',
      'created': 1700000001.0,
    };
    final imageItem = {
      'id': 'i1',
      'kind': 'image',
      'text': '截图',
      'path': '/tmp/i1.png',
      'fingerprint': 'bb',
      'created': 1700000002.0,
    };

    test('list 解析条目数组（含可选 path）', () async {
      handler = (_) => [textItem, imageItem];
      final bridge = MacosNativeBridge();
      final result = await bridge.historyList();
      expect(result.ok, isTrue);
      expect(result.value, hasLength(2));
      expect(result.value![0].kind, BridgeItemKind.text);
      expect(result.value![0].path, isNull);
      expect(result.value![1].kind, BridgeItemKind.image);
      expect(result.value![1].path, '/tmp/i1.png');
      expect(lastCall().method, 'history.list');
    });

    test('addText/addImage 返回新条目', () async {
      final bridge = MacosNativeBridge();
      handler = (call) =>
          call.method == 'history.addText' ? textItem : imageItem;
      final added = await bridge.historyAddText('条目');
      expect(added.value!.fingerprint, 'aa');
      expect(lastCall().arguments, {'text': '条目'});
      final png = Uint8List.fromList([7, 7]);
      final addedImage = await bridge.historyAddImage(png, title: '区域截图');
      expect(addedImage.value!.id, 'i1');
      expect(lastCall().arguments,
          {'dataBase64': base64Encode(png), 'title': '区域截图'});
    });

    test('copy/remove/clear 透传参数', () async {
      final bridge = MacosNativeBridge();
      await bridge.historyCopy('t1');
      expect(lastCall().method, 'history.copy');
      expect(lastCall().arguments, {'id': 't1'});
      await bridge.historyRemove('t1');
      expect(lastCall().method, 'history.remove');
      await bridge.historyClear();
      expect(lastCall().method, 'history.clear');
    });

    test('setPinned/isPinned 悬浮固定语义', () async {
      final bridge = MacosNativeBridge();
      await bridge.historySetPinned(true);
      expect(lastCall().method, 'history.setPinned');
      expect(lastCall().arguments, {'pinned': true});
      handler = (_) => true;
      final pinned = await bridge.historyIsPinned();
      expect(pinned.value, isTrue);
      expect(lastCall().method, 'history.isPinned');
    });

    test('删除不存在条目映射 not_found', () async {
      handler = (_) =>
          PlatformException(code: 'not_found', message: '历史条目不存在');
      final bridge = MacosNativeBridge();
      final result = await bridge.historyRemove('nope');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'not_found');
    });
  });

  group('permissions', () {
    test('status 解析两种权限', () async {
      handler = (_) => {'screenRecording': true, 'postEvent': false};
      final bridge = MacosNativeBridge();
      final result = await bridge.permissionsStatus();
      expect(result.ok, isTrue);
      expect(result.value![BridgePermission.screenRecording], isTrue);
      expect(result.value![BridgePermission.postEvent], isFalse);
      expect(lastCall().method, 'permissions.status');
    });

    test('request 获准返回 true', () async {
      handler = (_) => true;
      final bridge = MacosNativeBridge();
      final result =
          await bridge.permissionsRequest(BridgePermission.screenRecording);
      expect(result.ok, isTrue);
      expect(result.value, isTrue);
      expect(lastCall().arguments, {'type': 'screenRecording'});
    });

    test('request 被拒映射 permission_denied', () async {
      handler = (_) => denied();
      final bridge = MacosNativeBridge();
      final result =
          await bridge.permissionsRequest(BridgePermission.postEvent);
      expect(result.ok, isFalse);
      expect(result.errorCode, 'permission_denied');
    });
  });

  group('loginItem', () {
    test('set 透传 enabled，isEnabled 返回布尔', () async {
      final bridge = MacosNativeBridge();
      await bridge.loginItemSet(true);
      expect(lastCall().method, 'loginItem.set');
      expect(lastCall().arguments, {'enabled': true});
      handler = (_) => false;
      expect((await bridge.loginItemIsEnabled()).value, isFalse);
      expect(lastCall().method, 'loginItem.isEnabled');
    });

    test('低版本系统映射 unavailable', () async {
      handler = (_) =>
          PlatformException(code: 'unavailable', message: '需要 macOS 13+');
      final bridge = MacosNativeBridge();
      final result = await bridge.loginItemSet(true);
      expect(result.ok, isFalse);
      expect(result.errorCode, 'unavailable');
    });
  });

  group('notify', () {
    test('show 透传 title/body/id', () async {
      final bridge = MacosNativeBridge();
      await bridge.notifyShow(title: 't', body: 'b', id: 'd1');
      expect(lastCall().method, 'notify.show');
      expect(lastCall().arguments, {'title': 't', 'body': 'b', 'id': 'd1'});
    });

    test('系统错误映射 failure', () async {
      handler = (_) => systemError();
      final bridge = MacosNativeBridge();
      expect((await bridge.notifyShow(title: 't', body: 'b')).ok, isFalse);
    });
  });

  group('files', () {
    test('saveSent 返回落盘路径并透传参数', () async {
      handler = (_) => '/Users/x/Documents/CopySync/a.txt';
      final bridge = MacosNativeBridge();
      final data = Uint8List.fromList(utf8.encode('hi'));
      final result = await bridge.filesSaveSent(
          itemId: 'item-1', name: 'a.txt', data: data);
      expect(result.ok, isTrue);
      expect(result.value, endsWith('a.txt'));
      expect(lastCall().method, 'files.saveSent');
      expect(lastCall().arguments, {
        'itemId': 'item-1',
        'name': 'a.txt',
        'dataBase64': base64Encode(data),
      });
    });

    test('saveReceived 透传 deliveryId', () async {
      handler = (_) => '/tmp/x.png';
      final bridge = MacosNativeBridge();
      await bridge.filesSaveReceived(
          deliveryId: 'd1', name: 'x.png', data: Uint8List(0));
      expect(lastCall().method, 'files.saveReceived');
      expect((lastCall().arguments as Map)['deliveryId'], 'd1');
    });

    test('revealReceived 命中方法名；接收中映射 not_ready', () async {
      handler = (_) => '/Users/x/Documents/CopySync/b.zip';
      final bridge = MacosNativeBridge();
      final revealed =
          await bridge.filesRevealReceived(deliveryId: 'd1', name: 'b.zip');
      expect(revealed.ok, isTrue);
      expect(lastCall().method, 'files.revealReceived');
      handler = (_) =>
          PlatformException(code: 'not_ready', message: '文件仍在接收中');
      final pending = await bridge.filesRevealReceived(name: 'b.zip');
      expect(pending.ok, isFalse);
      expect(pending.errorCode, 'not_ready');
    });
  });

  group('cache', () {
    test('usage 解析五元组', () async {
      handler = (_) => {
            'historyCount': 3,
            'historyLimit': 10,
            'screenshotCount': 1,
            'screenshotBytes': 2048,
            'cacheBytes': 1024,
          };
      final bridge = MacosNativeBridge();
      final result = await bridge.cacheUsage();
      expect(result.ok, isTrue);
      final usage = result.value!;
      expect(usage.historyCount, 3);
      expect(usage.historyLimit, 10);
      expect(usage.screenshotCount, 1);
      expect(usage.screenshotBytes, 2048);
      expect(usage.cacheBytes, 1024);
      expect(lastCall().method, 'cache.usage');
    });

    test('clear 命中 cache.clear', () async {
      final bridge = MacosNativeBridge();
      await bridge.cacheClear();
      expect(lastCall().method, 'cache.clear');
    });
  });

  group('update', () {
    test('check 解析清单比较结果', () async {
      handler = (_) => {
            'current': '2.0',
            'latest': '2.2',
            'hasUpdate': true,
            'notes': '修复',
            'url': 'https://x/CopySync.zip',
            'sha256': 'ab',
          };
      final bridge = MacosNativeBridge();
      final result = await bridge.updateCheck('https://x/api/update/mac');
      expect(result.ok, isTrue);
      expect(result.value!.hasUpdate, isTrue);
      expect(result.value!.latest, '2.2');
      expect(lastCall().method, 'update.check');
      expect(lastCall().arguments, {'url': 'https://x/api/update/mac'});
    });

    test('download 返回 zip 路径；校验失败映射 checksum_mismatch', () async {
      handler = (_) => '/tmp/CopySync-update.zip';
      final bridge = MacosNativeBridge();
      final downloaded = await bridge.updateDownload(
          url: 'https://x/a.zip', sha256: 'ab');
      expect(downloaded.value, '/tmp/CopySync-update.zip');
      expect(lastCall().method, 'update.download');
      handler = (_) =>
          PlatformException(code: 'checksum_mismatch', message: '更新下载或校验失败');
      final bad =
          await bridge.updateDownload(url: 'https://x/a.zip', sha256: 'ab');
      expect(bad.ok, isFalse);
      expect(bad.errorCode, 'checksum_mismatch');
    });

    test('install 透传路径；失败映射 system_error', () async {
      final bridge = MacosNativeBridge();
      await bridge.updateInstall('/tmp/a.zip');
      expect(lastCall().method, 'update.install');
      expect(lastCall().arguments, {'path': '/tmp/a.zip'});
      handler = (_) => systemError();
      expect((await bridge.updateInstall('/tmp/a.zip')).ok, isFalse);
    });
  });

  group('事件流', () {
    test('原生 history.changed 事件进入 events 流', () async {
      final bridge = MacosNativeBridge();
      final future = bridge.events.first;
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'xyz.copysync/bridge',
        codec.encodeMethodCall(const MethodCall('history.changed')),
        (_) {},
      );
      final event = await future;
      expect(event.name, 'history.changed');
      expect(event.arguments, isNull);
    });

    test('原生 hotkey.pressed 携带 id', () async {
      final bridge = MacosNativeBridge();
      final future = bridge.events.first;
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'xyz.copysync/bridge',
        codec.encodeMethodCall(
            const MethodCall('hotkey.pressed', {'id': 'main'})),
        (_) {},
      );
      final event = await future;
      expect(event.name, 'hotkey.pressed');
      expect(event.arguments, {'id': 'main'});
    });
  });

  group('桥缺失', () {
    test('通道未注册时映射 unavailable，不抛异常', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final bridge = MacosNativeBridge();
      final result = await bridge.historyList();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'unavailable');
      expect(result.errorMessage, isNotEmpty);
    });
  });
}
