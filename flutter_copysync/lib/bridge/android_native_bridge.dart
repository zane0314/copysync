import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'android_bridge_models.dart';
import 'android_host.dart';
import 'bridge_models.dart';
import 'bridge_result.dart';
import 'update_checker.dart';

/// Android 原生桥接实现：MethodChannel `xyz.copysync/bridge`
/// （与 macOS 同通道名、不同方法集，原生侧错误经 PlatformException.code →
/// [BridgeResult.errorCode] 映射，MissingPluginException 映射为
/// [BridgeErrorCodes.unavailable]）。
///
/// 注意：`picker.files/photos` 不在此桥内——文件/图片选择已由
/// file_selector 插件覆盖（Android 走 SAF），属 delegated-to-plugin。
class AndroidNativeBridge implements UpdateChecker, AndroidHost {
  AndroidNativeBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onNativeEvent);
  }

  static const _channelName = 'xyz.copysync/bridge';

  final MethodChannel _channel;
  final StreamController<BridgeEvent> _events =
      StreamController<BridgeEvent>.broadcast();

  /// 原生 → Dart 事件流：目前为 `share.pending`（新分享到达）。
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

  static Uint8List? _decodeBase64(Object? raw) =>
      raw is String ? base64Decode(raw) : null;

  // ------------------------------------------------------------- clipboard

  /// Android 无系统剪贴板变化回调等价物且后台读取受限（API 29+），
  /// 不提供 watch；同步循环在 Dart 侧按需 read 去重。
  Future<BridgeResult<String?>> clipboardReadText() =>
      _invoke('clipboard.readText', null, (raw) => raw as String?);

  Future<BridgeResult<Uint8List?>> clipboardReadImage() =>
      _invoke('clipboard.readImage', null, _decodeBase64);

  /// 写入剪贴板（text 与 png 二选一）；[ignoreNext] 仅透传，
  /// Android 侧无原生 watcher，去重由 Dart 同步循环负责。
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

  // --------------------------------------------- background（前台服务保活）

  /// 启动前台服务（对应旧工程 SyncService；SSE/同步循环在 Dart 侧，
  /// 原生只管服务生命周期与常驻通知）。mode 为 realtime/saving。
  @override
  Future<BridgeResult<void>> backgroundStart({String mode = 'realtime'}) =>
      _invoke('background.start', {'mode': mode});

  @override
  Future<BridgeResult<void>> backgroundStop() => _invoke('background.stop');

  // ---------------------------------------------------------------- notify

  @override
  Future<BridgeResult<void>> notifyShow(
          {required String title, required String body, String? id}) =>
      _invoke('notify.show', {'title': title, 'body': body, 'id': ?id});

  // ----------------------------------------------------------------- share

  /// 拉取所有待确认分享（ACTION_SEND / SEND_MULTIPLE 由原生侧缓存，
  /// 文件已复制到应用缓存目录）。
  @override
  Future<BridgeResult<List<AndroidSharePayload>>> sharePending() =>
      _invoke('share.pending', null, (raw) =>
          (raw as List<Object?>? ?? const [])
              .map((e) =>
                  AndroidSharePayload.fromMap(e as Map<Object?, Object?>))
              .toList());

  /// 确认（发送完成或放弃）后调用，原生侧删除缓存文件与记录。
  @override
  Future<BridgeResult<void>> shareConfirm(List<String> ids) =>
      _invoke('share.confirm', {'ids': ids});

  // -------------------------------------------------------------- download

  /// 经 DownloadManager 入队下载到 Download/CopySync（旧工程语义），
  /// 返回系统下载 id；headers 用于携带 Cookie 等认证信息。
  @override
  Future<BridgeResult<int>> downloadEnqueue({
    required String url,
    required String deliveryId,
    required String name,
    required String mime,
    Map<String, String>? headers,
  }) =>
      _invoke(
          'download.enqueue',
          {
            'url': url,
            'deliveryId': deliveryId,
            'name': name,
            'mime': mime,
            'headers': ?headers,
          },
          (raw) => (raw as num?)?.toInt() ?? -1);

  /// 对账所有未完成下载（重启恢复语义）：返回每条 delivery 的
  /// ready/pending/failed/missing 状态。
  @override
  Future<BridgeResult<List<AndroidDownloadRecord>>> downloadReconcile() =>
      _invoke('download.reconcile', null, (raw) =>
          (raw as List<Object?>? ?? const [])
              .map((e) =>
                  AndroidDownloadRecord.fromMap(e as Map<Object?, Object?>))
              .toList());

  // ----------------------------------------------------------------- files

  /// 已发送文件落盘 Download/CopySync，返回最终文件名。
  @override
  Future<BridgeResult<String>> filesSaveSent(
          {required String itemId,
          required String name,
          required Uint8List data}) =>
      _invoke(
          'files.saveSent',
          {'itemId': itemId, 'name': name, 'dataBase64': base64Encode(data)},
          (raw) => raw as String? ?? '');

  /// 已接收文件落盘 Download/CopySync，返回最终文件名。
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

  /// 在系统文件管理器中定位接收文件（旧工程 revealReceivedFile 语义）。
  Future<BridgeResult<String>> filesRevealReceived(
          {String? deliveryId, required String name}) =>
      _invoke('files.revealReceived', {'name': name, 'deliveryId': ?deliveryId},
          (raw) => raw as String? ?? '');

  /// 调用系统查看器打开接收文件（旧工程 viewReceivedFile 语义）。
  @override
  Future<BridgeResult<void>> filesOpenReceived(
          {String? deliveryId, required String name, required String mime}) =>
      _invoke('files.openReceived',
          {'name': name, 'deliveryId': ?deliveryId, 'mime': mime});

  // ---------------------------------------------------------------- update

  /// 检查更新清单（旧工程 checkForUpdate：versionCode 比较）。
  @override
  Future<BridgeResult<UpdateInfo>> updateCheck(String manifestUrl) => _invoke(
      'update.check',
      {'url': manifestUrl},
      (raw) => UpdateInfo.fromMap(raw as Map<Object?, Object?>? ?? const {}));

  /// 下载 APK 并做 SHA-256 校验，成功返回落盘路径。
  @override
  Future<BridgeResult<String>> updateDownload(
          {required String url, required String sha256}) =>
      _invoke('update.download', {'url': url, 'sha256': sha256},
          (raw) => raw as String? ?? '');

  /// 发起安装（FileProvider 授权 + ACTION_VIEW APK）；
  /// 未允许未知来源时原生侧打开对应设置页并返回 permission_denied。
  @override
  Future<BridgeResult<void>> updateInstall(String apkPath) =>
      _invoke('update.install', {'path': apkPath});
}
