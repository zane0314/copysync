import 'dart:convert';

import 'package:copysync/bridge/android_bridge_models.dart';
import 'package:copysync/bridge/android_native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用 mock MethodChannel 验证 Android 桥接：成功路径解析 +
/// 权限拒绝/用户取消/系统错误/校验失败/桥缺失 全部映射为 BridgeResult，
/// 禁止静默失败。通道名与 macOS 相同（xyz.copysync/bridge），方法集不同。
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

  group('clipboard', () {
    test('readText 返回字符串，空剪贴板返回 null', () async {
      handler = (_) => '你好';
      final bridge = AndroidNativeBridge();
      expect((await bridge.clipboardReadText()).value, '你好');
      expect(lastCall().method, 'clipboard.readText');
      handler = (_) => null;
      expect((await bridge.clipboardReadText()).value, isNull);
    });

    test('readImage 返回 base64 解码后的 PNG 字节', () async {
      final png = Uint8List.fromList([1, 2, 3]);
      handler = (_) => base64Encode(png);
      final bridge = AndroidNativeBridge();
      final result = await bridge.clipboardReadImage();
      expect(result.ok, isTrue);
      expect(result.value, png);
      expect(lastCall().method, 'clipboard.readImage');
    });

    test('write 文本带 ignoreNext，图片走 dataBase64', () async {
      final bridge = AndroidNativeBridge();
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
      final bridge = AndroidNativeBridge();
      final result = await bridge.clipboardWrite();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_args');
      expect(calls, isEmpty);
    });

    test('写入失败映射 system_error', () async {
      handler = (_) => systemError();
      final bridge = AndroidNativeBridge();
      final result = await bridge.clipboardWrite(text: 'x');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'system_error');
    });
  });

  group('background（前台服务）', () {
    test('start 透传 mode，stop 命中方法名', () async {
      final bridge = AndroidNativeBridge();
      final started = await bridge.backgroundStart(mode: 'saving');
      expect(started.ok, isTrue);
      expect(lastCall().method, 'background.start');
      expect(lastCall().arguments, {'mode': 'saving'});
      await bridge.backgroundStop();
      expect(lastCall().method, 'background.stop');
    });

    test('无通知/前台服务权限映射 permission_denied', () async {
      handler = (_) => denied('通知权限未授予');
      final bridge = AndroidNativeBridge();
      final result = await bridge.backgroundStart();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'permission_denied');
    });
  });

  group('notify', () {
    test('show 透传 title/body/id', () async {
      final bridge = AndroidNativeBridge();
      await bridge.notifyShow(title: 't', body: 'b', id: 'd1');
      expect(lastCall().method, 'notify.show');
      expect(lastCall().arguments, {'title': 't', 'body': 'b', 'id': 'd1'});
    });

    test('系统错误映射 failure', () async {
      handler = (_) => systemError();
      final bridge = AndroidNativeBridge();
      expect((await bridge.notifyShow(title: 't', body: 'b')).ok, isFalse);
    });
  });

  group('share', () {
    final payload = {
      'id': 'share-1',
      'text': '分享的文本',
      'files': [
        {'name': 'a.png', 'mime': 'image/png', 'path': '/cache/share_inbox/a.png', 'size': 12},
      ],
    };

    test('pending 解析分享载荷（文本+文件）', () async {
      handler = (_) => [payload];
      final bridge = AndroidNativeBridge();
      final result = await bridge.sharePending();
      expect(result.ok, isTrue);
      expect(result.value, hasLength(1));
      final share = result.value!.first;
      expect(share.id, 'share-1');
      expect(share.text, '分享的文本');
      expect(share.files, hasLength(1));
      expect(share.files.first.name, 'a.png');
      expect(share.files.first.mime, 'image/png');
      expect(share.files.first.path, '/cache/share_inbox/a.png');
      expect(share.files.first.size, 12);
      expect(lastCall().method, 'share.pending');
    });

    test('pending 空列表返回空数组', () async {
      handler = (_) => <Object?>[];
      final bridge = AndroidNativeBridge();
      final result = await bridge.sharePending();
      expect(result.ok, isTrue);
      expect(result.value, isEmpty);
    });

    test('confirm 透传 id 列表', () async {
      final bridge = AndroidNativeBridge();
      final result = await bridge.shareConfirm(['share-1', 'share-2']);
      expect(result.ok, isTrue);
      expect(lastCall().method, 'share.confirm');
      expect(lastCall().arguments, {
        'ids': ['share-1', 'share-2'],
      });
    });

    test('读取分享内容失败映射 system_error', () async {
      handler = (_) => systemError();
      final bridge = AndroidNativeBridge();
      final result = await bridge.sharePending();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'system_error');
    });
  });

  group('download', () {
    test('enqueue 透传 url/deliveryId/name/mime/headers，返回下载 id', () async {
      handler = (_) => 42;
      final bridge = AndroidNativeBridge();
      final result = await bridge.downloadEnqueue(
        url: 'http://x/download/1',
        deliveryId: 'd1',
        name: 'a.zip',
        mime: 'application/zip',
        headers: {'Cookie': 'k=v'},
      );
      expect(result.ok, isTrue);
      expect(result.value, 42);
      expect(lastCall().method, 'download.enqueue');
      expect(lastCall().arguments, {
        'url': 'http://x/download/1',
        'deliveryId': 'd1',
        'name': 'a.zip',
        'mime': 'application/zip',
        'headers': {'Cookie': 'k=v'},
      });
    });

    test('reconcile 解析各状态（ready/pending/failed/missing）', () async {
      handler = (_) => [
            {'deliveryId': 'd1', 'name': 'a.zip', 'state': 'ready'},
            {'deliveryId': 'd2', 'name': 'b.zip', 'state': 'pending'},
            {'deliveryId': 'd3', 'name': 'c.zip', 'state': 'failed'},
            {'deliveryId': 'd4', 'name': 'd.zip', 'state': 'missing'},
          ];
      final bridge = AndroidNativeBridge();
      final result = await bridge.downloadReconcile();
      expect(result.ok, isTrue);
      expect(result.value, hasLength(4));
      expect(result.value![0].state, AndroidDownloadState.ready);
      expect(result.value![1].state, AndroidDownloadState.pending);
      expect(result.value![2].state, AndroidDownloadState.failed);
      expect(result.value![3].state, AndroidDownloadState.missing);
      expect(result.value![0].deliveryId, 'd1');
      expect(lastCall().method, 'download.reconcile');
    });

    test('入队失败映射 system_error', () async {
      handler = (_) => systemError();
      final bridge = AndroidNativeBridge();
      final result = await bridge.downloadEnqueue(
          url: 'http://x/a', deliveryId: 'd1', name: 'a', mime: '');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'system_error');
    });
  });

  group('files', () {
    test('saveSent 返回落盘名并透传参数', () async {
      handler = (_) => 'a.txt';
      final bridge = AndroidNativeBridge();
      final data = Uint8List.fromList(utf8.encode('hi'));
      final result = await bridge.filesSaveSent(
          itemId: 'item-1', name: 'a.txt', data: data);
      expect(result.ok, isTrue);
      expect(result.value, 'a.txt');
      expect(lastCall().method, 'files.saveSent');
      expect(lastCall().arguments, {
        'itemId': 'item-1',
        'name': 'a.txt',
        'dataBase64': base64Encode(data),
      });
    });

    test('saveReceived 透传 deliveryId', () async {
      handler = (_) => 'x.png';
      final bridge = AndroidNativeBridge();
      await bridge.filesSaveReceived(
          deliveryId: 'd1', name: 'x.png', data: Uint8List(0));
      expect(lastCall().method, 'files.saveReceived');
      expect((lastCall().arguments as Map)['deliveryId'], 'd1');
    });

    test('revealReceived 命中方法名；接收中映射 not_ready', () async {
      handler = (_) => 'b.zip';
      final bridge = AndroidNativeBridge();
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

    test('openReceived 透传 name/mime；无查看器映射 not_found', () async {
      final bridge = AndroidNativeBridge();
      final opened = await bridge.filesOpenReceived(
          deliveryId: 'd1', name: 'b.png', mime: 'image/png');
      expect(opened.ok, isTrue);
      expect(lastCall().method, 'files.openReceived');
      expect(lastCall().arguments,
          {'deliveryId': 'd1', 'name': 'b.png', 'mime': 'image/png'});
      handler = (_) =>
          PlatformException(code: 'not_found', message: '没有可打开该文件的应用');
      final missing =
          await bridge.filesOpenReceived(name: 'b.png', mime: 'image/png');
      expect(missing.ok, isFalse);
      expect(missing.errorCode, 'not_found');
    });

    test('openReceived 用户取消映射 cancelled', () async {
      handler = (_) => cancelled();
      final bridge = AndroidNativeBridge();
      final result =
          await bridge.filesOpenReceived(name: 'b.png', mime: 'image/png');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'cancelled');
    });
  });

  group('update', () {
    test('check 解析清单比较结果', () async {
      handler = (_) => {
            'current': '24',
            'latest': '25',
            'hasUpdate': true,
            'notes': '修复',
            'url': 'https://x/app.apk',
            'sha256': 'ab',
          };
      final bridge = AndroidNativeBridge();
      final result = await bridge.updateCheck('https://x/api/update/android');
      expect(result.ok, isTrue);
      expect(result.value!.hasUpdate, isTrue);
      expect(result.value!.latest, '25');
      expect(lastCall().method, 'update.check');
      expect(lastCall().arguments, {'url': 'https://x/api/update/android'});
    });

    test('download 返回 apk 路径；校验失败映射 checksum_mismatch', () async {
      handler = (_) => '/dl/CopySync-update.apk';
      final bridge = AndroidNativeBridge();
      final downloaded =
          await bridge.updateDownload(url: 'https://x/a.apk', sha256: 'ab');
      expect(downloaded.value, '/dl/CopySync-update.apk');
      expect(lastCall().method, 'update.download');
      expect(lastCall().arguments, {'url': 'https://x/a.apk', 'sha256': 'ab'});
      handler = (_) => PlatformException(
          code: 'checksum_mismatch', message: '更新下载或校验失败');
      final bad =
          await bridge.updateDownload(url: 'https://x/a.apk', sha256: 'ab');
      expect(bad.ok, isFalse);
      expect(bad.errorCode, 'checksum_mismatch');
    });

    test('install 透传路径；禁止安装未知来源映射 permission_denied', () async {
      final bridge = AndroidNativeBridge();
      await bridge.updateInstall('/dl/a.apk');
      expect(lastCall().method, 'update.install');
      expect(lastCall().arguments, {'path': '/dl/a.apk'});
      handler = (_) => denied('未允许安装未知来源应用');
      final result = await bridge.updateInstall('/dl/a.apk');
      expect(result.ok, isFalse);
      expect(result.errorCode, 'permission_denied');
    });
  });

  group('事件流', () {
    test('原生 share.pending 事件进入 events 流', () async {
      final bridge = AndroidNativeBridge();
      final future = bridge.events.first;
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'xyz.copysync/bridge',
        codec.encodeMethodCall(
            const MethodCall('share.pending', {'id': 'share-9'})),
        (_) {},
      );
      final event = await future;
      expect(event.name, 'share.pending');
      expect(event.arguments, {'id': 'share-9'});
    });
  });

  group('桥缺失', () {
    test('通道未注册时映射 unavailable，不抛异常', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final bridge = AndroidNativeBridge();
      final result = await bridge.sharePending();
      expect(result.ok, isFalse);
      expect(result.errorCode, 'unavailable');
      expect(result.errorMessage, isNotEmpty);
    });
  });
}
