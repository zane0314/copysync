import 'dart:typed_data';

import 'android_bridge_models.dart';
import 'bridge_models.dart';
import 'bridge_result.dart';

/// AppState / 页面层依赖的 Android 原生能力面（AndroidNativeBridge 实现）。
/// 抽接口是为了在单元测试中用内存 fake 驱动 分享确认/接收通知/下载/转存 流程。
abstract class AndroidHost {
  /// 原生 → Dart 事件流：`share.pending`（新分享到达）。
  Stream<BridgeEvent> get events;

  // clipboard
  Future<BridgeResult<void>> clipboardWrite(
      {String? text, Uint8List? png, bool ignoreNext = false});

  // background（前台服务保活）
  Future<BridgeResult<void>> backgroundStart({String mode});
  Future<BridgeResult<void>> backgroundStop();

  // notify
  Future<BridgeResult<void>> notifyShow(
      {required String title, required String body, String? id});

  // share
  Future<BridgeResult<List<AndroidSharePayload>>> sharePending();
  Future<BridgeResult<void>> shareConfirm(List<String> ids);

  // download（DownloadManager 入队 + 重启对账）
  Future<BridgeResult<int>> downloadEnqueue({
    required String url,
    required String deliveryId,
    required String name,
    required String mime,
    Map<String, String>? headers,
  });
  Future<BridgeResult<List<AndroidDownloadRecord>>> downloadReconcile();

  // files（落盘 Download/CopySync、系统查看器打开）
  Future<BridgeResult<String>> filesSaveSent({
    required String itemId,
    required String name,
    required Uint8List data,
  });
  Future<BridgeResult<void>> filesOpenReceived({
    String? deliveryId,
    required String name,
    required String mime,
  });
}
