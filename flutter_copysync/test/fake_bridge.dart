import 'dart:async';
import 'dart:typed_data';

import 'package:copysync/bridge/bridge_models.dart';
import 'package:copysync/bridge/bridge_result.dart';
import 'package:copysync/bridge/native_bridge.dart';

/// 内存版 NativeBridge：页面与历史浮窗 widget 测试用。
/// 事件经 [emit] 注入；调用记录公开可断言。
class FakeBridge implements NativeBridge {
  final _events = StreamController<BridgeEvent>.broadcast();

  List<BridgeHistoryItem> historyItems = [];
  bool pinned = false;
  bool loginItemEnabled = false;
  String? clipboardText;
  Uint8List? clipboardImage;
  CacheUsage cacheUsageValue = const CacheUsage(
    historyCount: 2,
    historyLimit: 10,
    screenshotCount: 1,
    screenshotBytes: 512,
    cacheBytes: 4096,
  );
  UpdateInfo updateInfo = const UpdateInfo(
    current: '1.0.0',
    latest: '1.1.0',
    hasUpdate: true,
    url: 'https://example.com/app.zip',
    sha256: 'abc',
  );

  /// 桥方法失败注入：非 null 时所有方法返回该错误。
  BridgeResult<T> Function<T>()? failWith;

  int cacheClearCount = 0;
  int historyAddTextCount = 0;
  int historyAddImageCount = 0;
  String? lastPasteText;
  Uint8List? lastPastePng;
  String? lastCopiedHistoryId;
  int watchStartCount = 0;
  BridgeHotkey? registeredHotkey;
  final List<BridgeHotkey> registeredHotkeys = [];
  int showMainWindowCount = 0;
  int toggleMainWindowCount = 0;
  final List<String> setStatusMessages = [];

  /// 非 null 时 screenshotCaptureRegion 返回该结果（默认用户取消）。
  BridgeResult<BridgeHistoryItem>? screenshotResult;
  String? lastUpdateManifestUrl;
  String? installedUpdatePath;

  void emit(String name, [Object? arguments]) {
    if (!_events.isClosed) _events.add(BridgeEvent(name, arguments));
  }

  Future<void> dispose() => _events.close();

  BridgeResult<T> _fail<T>() =>
      failWith!<T>();

  @override
  Stream<BridgeEvent> get events => _events.stream;

  @override
  Future<BridgeResult<void>> menubarSetStatus(
      {required bool ok, required String message}) async {
    if (failWith != null) return _fail();
    setStatusMessages.add(message);
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> menubarShowMainWindow() async {
    if (failWith != null) return _fail();
    showMainWindowCount += 1;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> menubarToggleMainWindow() async {
    if (failWith != null) return _fail();
    toggleMainWindowCount += 1;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> hotkeyRegister(BridgeHotkey hotkey,
      {HistoryShortcut? shortcut}) async {
    if (failWith != null) return _fail();
    registeredHotkey = hotkey;
    registeredHotkeys.add(hotkey);
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> hotkeyUnregister(BridgeHotkey hotkey) async =>
      failWith != null ? _fail() : const BridgeResult.success(null);

  @override
  Future<BridgeResult<bool>> clipboardWatchStart() async {
    if (failWith != null) return _fail();
    watchStartCount += 1;
    return const BridgeResult.success(true);
  }

  @override
  Future<BridgeResult<void>> clipboardWatchStop() async =>
      failWith != null ? _fail() : const BridgeResult.success(null);

  @override
  Future<BridgeResult<String?>> clipboardReadText() async =>
      failWith != null ? _fail() : BridgeResult.success(clipboardText);

  @override
  Future<BridgeResult<Uint8List?>> clipboardReadImage() async =>
      failWith != null ? _fail() : BridgeResult.success(clipboardImage);

  @override
  Future<BridgeResult<void>> clipboardWrite(
      {String? text, Uint8List? png, bool ignoreNext = false}) async {
    if (failWith != null) return _fail();
    clipboardText = text;
    clipboardImage = png;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> clipboardIgnoreNext() async =>
      failWith != null ? _fail() : const BridgeResult.success(null);

  @override
  Future<BridgeResult<BridgeHistoryItem>> screenshotCaptureRegion() async {
    if (failWith != null) return _fail();
    return screenshotResult ??
        const BridgeResult.failure(
            errorCode: BridgeErrorCodes.cancelled, errorMessage: '已取消');
  }

  @override
  Future<BridgeResult<void>> pasteIntoPreviousApp(
      {String? text, Uint8List? png}) async {
    if (failWith != null) return _fail();
    lastPasteText = text;
    lastPastePng = png;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<List<BridgeHistoryItem>>> historyList() async =>
      failWith != null ? _fail() : BridgeResult.success(List.of(historyItems));

  @override
  Future<BridgeResult<BridgeHistoryItem>> historyAddText(String text) async {
    if (failWith != null) return _fail();
    historyAddTextCount += 1;
    final item = BridgeHistoryItem(
      id: 'h-${historyItems.length + 1}',
      kind: BridgeItemKind.text,
      text: text,
      fingerprint: 'fp-$text',
      created: historyItems.length + 1,
    );
    historyItems.insert(0, item);
    return BridgeResult.success(item);
  }

  @override
  Future<BridgeResult<BridgeHistoryItem>> historyAddImage(Uint8List png,
      {String title = '图片'}) async {
    if (failWith != null) return _fail();
    historyAddImageCount += 1;
    final item = BridgeHistoryItem(
      id: 'h-${historyItems.length + 1}',
      kind: BridgeItemKind.image,
      text: title,
      fingerprint: 'fp-img-${historyItems.length + 1}',
      created: historyItems.length + 1,
    );
    historyItems.insert(0, item);
    return BridgeResult.success(item);
  }

  @override
  Future<BridgeResult<void>> historyCopy(String id) async {
    if (failWith != null) return _fail();
    lastCopiedHistoryId = id;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> historyRemove(String id) async {
    if (failWith != null) return _fail();
    historyItems.removeWhere((i) => i.id == id);
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> historyClear() async {
    if (failWith != null) return _fail();
    historyItems.clear();
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<void>> historySetPinned(bool pinned) async {
    if (failWith != null) return _fail();
    this.pinned = pinned;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<bool>> historyIsPinned() async =>
      failWith != null ? _fail() : BridgeResult.success(pinned);

  @override
  Future<BridgeResult<Map<BridgePermission, bool>>> permissionsStatus() async =>
      failWith != null
          ? _fail()
          : const BridgeResult.success({
              BridgePermission.screenRecording: true,
              BridgePermission.postEvent: false,
            });

  @override
  Future<BridgeResult<bool>> permissionsRequest(
          BridgePermission permission) async =>
      failWith != null ? _fail() : const BridgeResult.success(true);

  @override
  Future<BridgeResult<void>> loginItemSet(bool enabled) async {
    if (failWith != null) return _fail();
    loginItemEnabled = enabled;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<bool>> loginItemIsEnabled() async =>
      failWith != null ? _fail() : BridgeResult.success(loginItemEnabled);

  @override
  Future<BridgeResult<void>> notifyShow(
          {required String title, required String body, String? id}) async =>
      failWith != null ? _fail() : const BridgeResult.success(null);

  @override
  Future<BridgeResult<String>> filesSaveSent(
          {required String itemId,
          required String name,
          required Uint8List data}) async =>
      failWith != null ? _fail() : BridgeResult.success(name);

  @override
  Future<BridgeResult<String>> filesSaveReceived(
          {required String deliveryId,
          required String name,
          required Uint8List data}) async =>
      failWith != null ? _fail() : BridgeResult.success(name);

  @override
  Future<BridgeResult<String>> filesRevealReceived(
          {String? deliveryId, required String name}) async =>
      failWith != null ? _fail() : BridgeResult.success(name);

  @override
  Future<BridgeResult<CacheUsage>> cacheUsage() async =>
      failWith != null ? _fail() : BridgeResult.success(cacheUsageValue);

  @override
  Future<BridgeResult<void>> cacheClear() async {
    if (failWith != null) return _fail();
    cacheClearCount += 1;
    return const BridgeResult.success(null);
  }

  @override
  Future<BridgeResult<UpdateInfo>> updateCheck(String manifestUrl) async {
    if (failWith != null) return _fail();
    lastUpdateManifestUrl = manifestUrl;
    return BridgeResult.success(updateInfo);
  }

  @override
  Future<BridgeResult<String>> updateDownload(
          {required String url, required String sha256}) async =>
      failWith != null ? _fail() : const BridgeResult.success('/tmp/app.zip');

  @override
  Future<BridgeResult<void>> updateInstall(String zipPath) async {
    if (failWith != null) return _fail();
    installedUpdatePath = zipPath;
    return const BridgeResult.success(null);
  }
}
