import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../bridge/bridge_models.dart';
import '../bridge/native_bridge.dart';
import 'app_state.dart';

/// macOS 键盘优先历史浮窗状态：监听桥事件（hotkey.pressed /
/// menubar.action(toggleHistory) 弹出，clipboard.changed 同步本地历史），
/// 输入即搜索、方向键选择、回车复制并粘贴到前一应用。
class HistoryController extends ChangeNotifier {
  HistoryController({required this.bridge});

  final NativeBridge bridge;

  StreamSubscription<BridgeEvent>? _sub;
  bool _started = false;

  List<BridgeHistoryItem> items = [];
  OpStatus loadStatus = OpStatus.idle;
  String? error;
  String query = '';
  int selectedIndex = 0;
  bool visible = false;
  bool pinned = false;

  List<BridgeHistoryItem> get filtered {
    if (query.isEmpty) return items;
    final q = query.toLowerCase();
    return items.where((i) => i.text.toLowerCase().contains(q)).toList();
  }

  /// 启动事件监听、剪贴板 watch 与历史快捷键注册；桥失败仅记录不阻塞。
  void start() {
    if (_started) return;
    _started = true;
    _sub = bridge.events.listen(_onEvent);
    _ignore(bridge.clipboardWatchStart());
    _ignore(bridge.hotkeyRegister(BridgeHotkey.history,
        shortcut: HistoryShortcut.commandComma));
    refresh();
  }

  Future<void> _ignore(Future<Object?> future) async {
    try {
      await future;
    } catch (_) {
      // 桥不可用（如测试环境）不阻断应用。
    }
  }

  Future<void> refresh() async {
    loadStatus = OpStatus.loading;
    notifyListeners();
    final list = await bridge.historyList();
    final pinnedResult = await bridge.historyIsPinned();
    if (list.ok) {
      items = list.value ?? [];
      loadStatus = OpStatus.success;
      error = null;
    } else {
      loadStatus = OpStatus.error;
      error = list.errorMessage ?? '历史读取失败';
    }
    if (pinnedResult.ok) pinned = pinnedResult.value ?? false;
    notifyListeners();
  }

  void _onEvent(BridgeEvent event) {
    final args = event.arguments;
    switch (event.name) {
      case 'hotkey.pressed':
        if (args is Map && args['id'] == 'history') toggle();
      case 'menubar.action':
        if (args is Map && args['action'] == 'toggleHistory') toggle();
        if (args is Map && args['action'] == 'openHistory' && !visible) {
          toggle();
        }
      case 'clipboard.changed':
        _ignore(_onClipboardChanged(args));
    }
  }

  /// 原生侧 watcher 已完成去重与 history.add* 写入（ignoreNext 在原生层
  /// 处理，被忽略的变化不产生事件），事件 payload 即新条目，这里只同步 UI；
  /// 无 payload 时回退为主动读取剪贴板并写入（add 有 SHA-256 去重）。
  Future<void> _onClipboardChanged(Object? args) async {
    if (args is Map && args['id'] != null) {
      _upsertLocal(
          BridgeHistoryItem.fromMap(args.cast<Object?, Object?>()));
      return;
    }
    final text = await bridge.clipboardReadText();
    if (text.ok && (text.value?.isNotEmpty ?? false)) {
      final added = await bridge.historyAddText(text.value!);
      if (added.ok && added.value != null) _upsertLocal(added.value!);
      return;
    }
    final image = await bridge.clipboardReadImage();
    if (image.ok && image.value != null) {
      final added = await bridge.historyAddImage(image.value!);
      if (added.ok && added.value != null) _upsertLocal(added.value!);
    }
  }

  void _upsertLocal(BridgeHistoryItem item) {
    items.removeWhere((i) => i.id == item.id);
    items.insert(0, item);
    notifyListeners();
  }

  void toggle() {
    visible = !visible;
    if (visible) {
      query = '';
      selectedIndex = 0;
      _ignore(refresh());
    }
    notifyListeners();
  }

  void hide() {
    if (!visible) return;
    visible = false;
    notifyListeners();
  }

  void setQuery(String value) {
    query = value;
    selectedIndex = 0;
    notifyListeners();
  }

  void moveSelection(int delta) {
    final count = filtered.length;
    if (count == 0) return;
    selectedIndex = (selectedIndex + delta).clamp(0, count - 1);
    notifyListeners();
  }

  /// 回车：复制选中条目并粘贴到前一应用，成功后关闭浮窗。
  Future<bool> pasteSelected() async {
    final list = filtered;
    if (list.isEmpty || selectedIndex >= list.length) return false;
    final item = list[selectedIndex];
    final copied = await bridge.historyCopy(item.id);
    if (!copied.ok) {
      error = copied.errorMessage ?? '复制失败';
      notifyListeners();
      return false;
    }
    final pasted = item.kind == BridgeItemKind.image
        ? await bridge.pasteIntoPreviousApp(png: await _readImageBytes(item))
        : await bridge.pasteIntoPreviousApp(text: item.text);
    if (!pasted.ok) {
      error = pasted.errorMessage ?? '粘贴失败';
      notifyListeners();
      return false;
    }
    if (!pinned) hide();
    notifyListeners();
    return true;
  }

  Future<Uint8List?> _readImageBytes(BridgeHistoryItem item) async {
    final path = item.path;
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// 悬浮固定开关（history.setPinned）。
  Future<void> togglePinned() async {
    final result = await bridge.historySetPinned(!pinned);
    if (result.ok) {
      pinned = !pinned;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
