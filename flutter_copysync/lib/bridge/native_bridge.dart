import 'dart:typed_data';

import 'bridge_models.dart';
import 'bridge_result.dart';
import 'update_checker.dart';

/// 原生桥接统一接口（接口锁定见实施计划 Task 21）。
/// 每个方法返回 [BridgeResult]，禁止静默失败。
/// 页面接线在 Task 24 完成，本接口只定义能力面。
abstract class NativeBridge implements UpdateChecker {
  /// 原生 → Dart 事件流：
  /// `clipboard.changed`、`history.changed`、`hotkey.pressed`、`menubar.action`。
  Stream<BridgeEvent> get events;

  // menubar.*
  Future<BridgeResult<void>> menubarSetStatus(
      {required bool ok, required String message});
  Future<BridgeResult<void>> menubarShowMainWindow();
  Future<BridgeResult<void>> menubarToggleMainWindow();

  // hotkey.*
  Future<BridgeResult<void>> hotkeyRegister(BridgeHotkey hotkey,
      {HistoryShortcut? shortcut});
  Future<BridgeResult<void>> hotkeyUnregister(BridgeHotkey hotkey);

  // clipboard.*
  Future<BridgeResult<bool>> clipboardWatchStart();
  Future<BridgeResult<void>> clipboardWatchStop();
  Future<BridgeResult<String?>> clipboardReadText();
  Future<BridgeResult<Uint8List?>> clipboardReadImage();

  /// 写入剪贴板（text 与 png 二选一）；[ignoreNext] 对应旧的
  /// ignoreNextCopy 语义：下一次复制变化不进入历史。
  Future<BridgeResult<void>> clipboardWrite(
      {String? text, Uint8List? png, bool ignoreNext = false});
  Future<BridgeResult<void>> clipboardIgnoreNext();

  // screenshot / paste
  Future<BridgeResult<BridgeHistoryItem>> screenshotCaptureRegion();
  Future<BridgeResult<void>> pasteIntoPreviousApp(
      {String? text, Uint8List? png});

  // history.*（本地历史 + SHA-256 去重置顶 + 悬浮固定，上限 10 条）
  Future<BridgeResult<List<BridgeHistoryItem>>> historyList();
  Future<BridgeResult<BridgeHistoryItem>> historyAddText(String text);
  Future<BridgeResult<BridgeHistoryItem>> historyAddImage(Uint8List png,
      {String title = '图片'});
  Future<BridgeResult<void>> historyCopy(String id);
  Future<BridgeResult<void>> historyRemove(String id);
  Future<BridgeResult<void>> historyClear();
  Future<BridgeResult<void>> historySetPinned(bool pinned);
  Future<BridgeResult<bool>> historyIsPinned();

  // permissions.*
  Future<BridgeResult<Map<BridgePermission, bool>>> permissionsStatus();
  Future<BridgeResult<bool>> permissionsRequest(BridgePermission permission);

  // loginItem.*
  Future<BridgeResult<void>> loginItemSet(bool enabled);
  Future<BridgeResult<bool>> loginItemIsEnabled();

  // notify.*
  Future<BridgeResult<void>> notifyShow(
      {required String title, required String body, String? id});

  // files.*（落盘 ~/Documents/CopySync 并可在 Finder 定位）
  Future<BridgeResult<String>> filesSaveSent(
      {required String itemId, required String name, required Uint8List data});
  Future<BridgeResult<String>> filesSaveReceived(
      {required String deliveryId,
      required String name,
      required Uint8List data});
  Future<BridgeResult<String>> filesRevealReceived(
      {String? deliveryId, required String name});

  // cache.*
  Future<BridgeResult<CacheUsage>> cacheUsage();
  Future<BridgeResult<void>> cacheClear();

  // update.* 由 UpdateChecker 接口继承（download 内含 SHA-256 校验，
  // install 为覆盖安装+重启）。
}
