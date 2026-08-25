import 'dart:async';
import 'dart:typed_data';

import 'package:copysync/bridge/android_bridge_models.dart';
import 'package:copysync/bridge/android_host.dart';
import 'package:copysync/bridge/bridge_models.dart';
import 'package:copysync/bridge/bridge_result.dart';

/// 内存版 AndroidHost：AppState / 分享对话框测试用。
class FakeAndroidHost implements AndroidHost {
  final _events = StreamController<BridgeEvent>.broadcast();

  int backgroundStartCount = 0;
  int backgroundStopCount = 0;
  final List<String> notifications = [];
  final List<List<String>> confirmedShareIds = [];
  List<AndroidSharePayload> pendingShares = [];
  final List<Map<String, Object?>> enqueued = [];
  final List<Map<String, Object?>> savedSent = [];
  final List<Map<String, Object?>> openedReceived = [];
  String? lastClipboardText;
  List<AndroidDownloadRecord> reconcileResult = [];
  bool failEnqueue = false;

  void emit(String name, [Object? arguments]) {
    if (!_events.isClosed) _events.add(BridgeEvent(name, arguments));
  }

  Future<void> dispose() => _events.close();

  @override
  Stream<BridgeEvent> get events => _events.stream;

  @override
  Future<BridgeResult<void>> clipboardWrite(
      {String? text, Uint8List? png, bool ignoreNext = false}) async {
    lastClipboardText = text;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> backgroundStart({String mode = 'realtime'}) async {
    backgroundStartCount += 1;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> backgroundStop() async {
    backgroundStopCount += 1;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> notifyShow(
      {required String title, required String body, String? id}) async {
    notifications.add('$title|$body|$id');
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<List<AndroidSharePayload>>> sharePending() async =>
      BridgeResult.success(List.of(pendingShares));

  @override
  Future<BridgeResult<void>> shareConfirm(List<String> ids) async {
    confirmedShareIds.add(ids);
    pendingShares.removeWhere((p) => ids.contains(p.id));
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<int>> downloadEnqueue({
    required String url,
    required String deliveryId,
    required String name,
    required String mime,
    Map<String, String>? headers,
  }) async {
    if (failEnqueue) {
      return const BridgeResult.failure(
          errorCode: 'system_error', errorMessage: '下载服务不可用');
    }
    enqueued.add({
      'url': url,
      'deliveryId': deliveryId,
      'name': name,
      'mime': mime,
      'headers': headers,
    });
    return BridgeResult.success(1000 + enqueued.length);
  }

  @override
  Future<BridgeResult<List<AndroidDownloadRecord>>> downloadReconcile() async =>
      BridgeResult.success(reconcileResult);

  @override
  Future<BridgeResult<String>> filesSaveSent(
      {required String itemId,
      required String name,
      required Uint8List data}) async {
    savedSent.add({'itemId': itemId, 'name': name, 'size': data.length});
    return BridgeResult.success('sent:$name');
  }

  @override
  Future<BridgeResult<void>> filesOpenReceived(
      {String? deliveryId, required String name, required String mime}) async {
    openedReceived.add(
        {'deliveryId': deliveryId, 'name': name, 'mime': mime});
    return const BridgeResult.success(null);
  }
}
