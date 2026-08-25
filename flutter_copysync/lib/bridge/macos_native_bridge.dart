import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'bridge_models.dart';
import 'bridge_result.dart';
import 'native_bridge.dart';

/// macOS 原生桥接实现：MethodChannel `xyz.copysync/bridge`。
/// 原生侧错误经 PlatformException.code → [BridgeResult.errorCode] 映射，
/// MissingPluginException（桥未注册）映射为 [BridgeErrorCodes.unavailable]。
class MacosNativeBridge implements NativeBridge {
  MacosNativeBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onNativeEvent);
  }

  static const _channelName = 'xyz.copysync/bridge';

  final MethodChannel _channel;
  final StreamController<BridgeEvent> _events =
      StreamController<BridgeEvent>.broadcast();

  @override
  Stream<BridgeEvent> get events => _events.stream;

  /// 原生侧反向调用统一视为事件（不做请求/应答）。
  Future<void> _onNativeEvent(MethodCall call) async {
    if (!_events.isClosed) _events.add(BridgeEvent(call.method, call.arguments));
  }

  Future<BridgeResult<T>> _invoke<T>(
    String method, [
    Object? arguments,
    T Function(Object? raw)? parse,
  ]) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method, arguments);
      return BridgeResult.success(parse != null ? parse(raw) : raw as T?);
    } on PlatformException catch (e) {
      return BridgeResult.failure(
          errorCode: e.code,
          errorMessage: e.message ?? '原生错误（${e.code}）');
    } on MissingPluginException {
      return const BridgeResult.failure(
          errorCode: BridgeErrorCodes.unavailable,
          errorMessage: '原生桥接未注册');
    }
  }

  static BridgeHistoryItem _item(Object? raw) =>
      BridgeHistoryItem.fromMap(raw as Map<Object?, Object?>);

  static Uint8List? _decodeBase64(Object? raw) =>
      raw is String ? base64Decode(raw) : null;

  // ---------------------------------------------------------------- menubar

  @override
  Future<BridgeResult<void>> menubarSetStatus(
          {required bool ok, required String message}) =>
      _invoke('menubar.setStatus', {'ok': ok, 'message': message});

  @override
  Future<BridgeResult<void>> menubarShowMainWindow() =>
      _invoke('menubar.showMainWindow');

  @override
  Future<BridgeResult<void>> menubarToggleMainWindow() =>
      _invoke('menubar.toggleMainWindow');

  // ---------------------------------------------------------------- hotkey

  @override
  Future<BridgeResult<void>> hotkeyRegister(BridgeHotkey hotkey,
      {HistoryShortcut? shortcut}) {
    final args = <String, Object?>{'id': hotkey.name};
    if (hotkey == BridgeHotkey.history && shortcut != null) {
      args['shortcut'] = shortcut.name;
    }
    return _invoke('hotkey.register', args);
  }

  @override
  Future<BridgeResult<void>> hotkeyUnregister(BridgeHotkey hotkey) =>
      _invoke('hotkey.unregister', {'id': hotkey.name});

  // ------------------------------------------------------------- clipboard

  @override
  Future<BridgeResult<bool>> clipboardWatchStart() =>
      _invoke('clipboard.watch', null, (raw) => raw == true);

  @override
  Future<BridgeResult<void>> clipboardWatchStop() => _invoke('clipboard.stop');

  @override
  Future<BridgeResult<String?>> clipboardReadText() =>
      _invoke('clipboard.readText', null, (raw) => raw as String?);

  @override
  Future<BridgeResult<Uint8List?>> clipboardReadImage() =>
      _invoke('clipboard.readImage', null, _decodeBase64);

  @override
  Future<BridgeResult<void>> clipboardWrite(
      {String? text, Uint8List? png, bool ignoreNext = false}) {
    Map<String, Object?>? args;
    if (text != null) {
      args = {'kind': 'text', 'text': text, 'ignoreNext': ignoreNext};
    } else if (png != null) {
      args = {
        'kind': 'image',
        'dataBase64': base64Encode(png),
        'ignoreNext': ignoreNext,
      };
    }
    if (args == null) {
      return Future.value(const BridgeResult.failure(
          errorCode: BridgeErrorCodes.invalidArgs,
          errorMessage: 'clipboardWrite 需要 text 或 png'));
    }
    return _invoke('clipboard.write', args);
  }

  @override
  Future<BridgeResult<void>> clipboardIgnoreNext() =>
      _invoke('clipboard.ignoreNext');

  // ---------------------------------------------------- screenshot / paste

  @override
  Future<BridgeResult<BridgeHistoryItem>> screenshotCaptureRegion() =>
      _invoke('screenshot.captureRegion', null, _item);

  @override
  Future<BridgeResult<void>> pasteIntoPreviousApp(
      {String? text, Uint8List? png}) {
    Map<String, Object?>? args;
    if (text != null) {
      args = {'kind': 'text', 'text': text};
    } else if (png != null) {
      args = {'kind': 'image', 'dataBase64': base64Encode(png)};
    }
    if (args == null) {
      return Future.value(const BridgeResult.failure(
          errorCode: BridgeErrorCodes.invalidArgs,
          errorMessage: 'pasteIntoPreviousApp 需要 text 或 png'));
    }
    return _invoke('paste.intoPreviousApp', args);
  }

  // --------------------------------------------------------------- history

  @override
  Future<BridgeResult<List<BridgeHistoryItem>>> historyList() =>
      _invoke('history.list', null, (raw) => (raw as List<Object?>? ?? [])
          .map((e) => BridgeHistoryItem.fromMap(e as Map<Object?, Object?>))
          .toList());

  @override
  Future<BridgeResult<BridgeHistoryItem>> historyAddText(String text) =>
      _invoke('history.addText', {'text': text}, _item);

  @override
  Future<BridgeResult<BridgeHistoryItem>> historyAddImage(Uint8List png,
          {String title = '图片'}) =>
      _invoke('history.addImage',
          {'dataBase64': base64Encode(png), 'title': title}, _item);

  @override
  Future<BridgeResult<void>> historyCopy(String id) =>
      _invoke('history.copy', {'id': id});

  @override
  Future<BridgeResult<void>> historyRemove(String id) =>
      _invoke('history.remove', {'id': id});

  @override
  Future<BridgeResult<void>> historyClear() => _invoke('history.clear');

  @override
  Future<BridgeResult<void>> historySetPinned(bool pinned) =>
      _invoke('history.setPinned', {'pinned': pinned});

  @override
  Future<BridgeResult<bool>> historyIsPinned() =>
      _invoke('history.isPinned', null, (raw) => raw == true);

  // ----------------------------------------------------------- permissions

  @override
  Future<BridgeResult<Map<BridgePermission, bool>>> permissionsStatus() =>
      _invoke('permissions.status', null, (raw) {
        final map = raw as Map<Object?, Object?>? ?? const {};
        return {
          BridgePermission.screenRecording:
              map['screenRecording'] as bool? ?? false,
          BridgePermission.postEvent: map['postEvent'] as bool? ?? false,
        };
      });

  @override
  Future<BridgeResult<bool>> permissionsRequest(BridgePermission permission) =>
      _invoke('permissions.request', {'type': permission.name},
          (raw) => raw == true);

  // ------------------------------------------------------------ login item

  @override
  Future<BridgeResult<void>> loginItemSet(bool enabled) =>
      _invoke('loginItem.set', {'enabled': enabled});

  @override
  Future<BridgeResult<bool>> loginItemIsEnabled() =>
      _invoke('loginItem.isEnabled', null, (raw) => raw == true);

  // ---------------------------------------------------------------- notify

  @override
  Future<BridgeResult<void>> notifyShow(
          {required String title, required String body, String? id}) =>
      _invoke('notify.show',
          {'title': title, 'body': body, 'id': ?id});

  // ----------------------------------------------------------------- files

  @override
  Future<BridgeResult<String>> filesSaveSent(
          {required String itemId,
          required String name,
          required Uint8List data}) =>
      _invoke(
          'files.saveSent',
          {'itemId': itemId, 'name': name, 'dataBase64': base64Encode(data)},
          (raw) => raw as String? ?? '');

  @override
  Future<BridgeResult<String>> filesSaveReceived(
          {required String deliveryId,
          required String name,
          required Uint8List data}) =>
      _invoke(
          'files.saveReceived',
          {
            'deliveryId': deliveryId,
            'name': name,
            'dataBase64': base64Encode(data),
          },
          (raw) => raw as String? ?? '');

  @override
  Future<BridgeResult<String>> filesRevealReceived(
          {String? deliveryId, required String name}) =>
      _invoke(
          'files.revealReceived',
          {'name': name, 'deliveryId': ?deliveryId},
          (raw) => raw as String? ?? '');

  // ----------------------------------------------------------------- cache

  @override
  Future<BridgeResult<CacheUsage>> cacheUsage() => _invoke(
      'cache.usage',
      null,
      (raw) => CacheUsage.fromMap(raw as Map<Object?, Object?>? ?? const {}));

  @override
  Future<BridgeResult<void>> cacheClear() => _invoke('cache.clear');

  // ---------------------------------------------------------------- update

  @override
  Future<BridgeResult<UpdateInfo>> updateCheck(String manifestUrl) => _invoke(
      'update.check',
      {'url': manifestUrl},
      (raw) => UpdateInfo.fromMap(raw as Map<Object?, Object?>? ?? const {}));

  @override
  Future<BridgeResult<String>> updateDownload(
          {required String url, required String sha256}) =>
      _invoke('update.download', {'url': url, 'sha256': sha256},
          (raw) => raw as String? ?? '');

  @override
  Future<BridgeResult<void>> updateInstall(String zipPath) =>
      _invoke('update.install', {'path': zipPath});
}
