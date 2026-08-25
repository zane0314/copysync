import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bridge_models.dart';
import '../bridge/bridge_result.dart';
import '../bridge/native_bridge.dart';
import 'history_controller.dart';

/// macOS 菜单栏动作与主窗口/截图快捷键的 Dart 侧接线。
/// 原生 NSMenu 每项只发 `menubar.action` 事件（迁移自 CopySync.m 菜单），
/// 这里分发到真实能力；危险动作经 [confirmHandler]（UI 注入对话框）
/// 二次确认后才执行，无处理器时一律不动。
class MenuCoordinator extends ChangeNotifier {
  MenuCoordinator({required this.bridge, this.history});

  final NativeBridge bridge;
  final HistoryController? history;

  /// 与设置页共用的 macOS 更新清单地址。
  static const macUpdateManifest = 'https://copy-direct.example.com/api/update/mac';

  /// 切换主窗口到指定 tab（0 收件箱 / 1 传输历史 / 2 临时网盘 / 3 设置），
  /// 由 HomeShell 注入。
  void Function(int index)? onSelectTab;

  /// 危险动作二次确认（返回 true 才执行），由 HomeShell 注入对话框。
  Future<bool> Function(String title, String message)? confirmHandler;

  StreamSubscription<BridgeEvent>? _sub;
  bool _started = false;

  /// 底部状态栏（旧版"显示底部状态栏"开关语义）可见性与内容。
  bool footerVisible = false;
  String statusMessage = '等待复制';

  /// 订阅桥事件并注册主窗口（⌘.）与区域截图（⌘J）快捷键；
  /// 历史快捷键（⌘, 等）由 HistoryController 注册。
  void start() {
    if (_started) return;
    _started = true;
    _sub = bridge.events.listen(_onEvent);
    _ignore(bridge.hotkeyRegister(BridgeHotkey.main));
    _ignore(bridge.hotkeyRegister(BridgeHotkey.screenshot));
  }

  void _onEvent(BridgeEvent event) {
    final args = event.arguments;
    if (event.name == 'hotkey.pressed' && args is Map) {
      switch (args['id']) {
        case 'main':
          _ignore(bridge.menubarToggleMainWindow());
        case 'screenshot':
          _ignore(captureRegion());
      }
      return;
    }
    if (event.name != 'menubar.action' || args is! Map) return;
    switch (args['action']) {
      case 'openTransfers':
        _showTab(1);
      case 'openPreferences':
        _showTab(3);
      case 'captureRegion':
        _ignore(captureRegion());
      case 'clearHistory':
        _ignore(_clearWithConfirm(
          '清空历史记录？',
          '将删除全部本地历史与历史截图，不可恢复。',
          bridge.historyClear,
          '历史已清空',
        ));
      case 'clearCache':
        _ignore(_clearWithConfirm(
          '清理临时缓存？',
          '将删除临时文件缓存目录内容。',
          bridge.cacheClear,
          '缓存已清理',
        ));
      case 'checkUpdate':
        _ignore(checkUpdates());
      case 'toggleFooter':
        toggleFooter();
    }
  }

  /// 区域截图：成功进历史并刷新浮窗；用户取消不动状态。
  Future<void> captureRegion() async {
    final result = await bridge.screenshotCaptureRegion();
    if (result.ok) {
      _setStatus('区域截图已保存到历史');
      _ignore(history?.refresh() ?? Future<void>.value());
    } else if (result.errorCode != BridgeErrorCodes.cancelled) {
      _setStatus(result.errorMessage ?? '截图失败');
    }
  }

  /// 检查更新（菜单栏入口）：结果写入状态栏，有新版时引导到设置页安装。
  Future<void> checkUpdates() async {
    _setStatus('正在检查更新…');
    final result = await bridge.updateCheck(macUpdateManifest);
    if (!result.ok || result.value == null) {
      _setStatus(result.errorMessage ?? '检查更新失败');
      return;
    }
    final info = result.value!;
    _setStatus(info.hasUpdate
        ? '发现新版本 ${info.latest}（当前 ${info.current}）'
        : '已经是最新版 ${info.current}');
    if (info.hasUpdate) _showTab(3);
  }

  void toggleFooter() {
    footerVisible = !footerVisible;
    notifyListeners();
  }

  void _showTab(int index) {
    _ignore(bridge.menubarShowMainWindow());
    onSelectTab?.call(index);
  }

  Future<void> _clearWithConfirm(
    String title,
    String message,
    Future<BridgeResult<void>> Function() action,
    String doneMessage,
  ) async {
    final confirm = confirmHandler;
    if (confirm == null) return; // 无 UI 上下文时危险动作不执行
    if (!await confirm(title, message)) return;
    final result = await action();
    _setStatus(result.ok ? doneMessage : (result.errorMessage ?? '操作失败'));
    if (result.ok) _ignore(history?.refresh() ?? Future<void>.value());
  }

  void _setStatus(String message) {
    statusMessage = message;
    notifyListeners();
    _ignore(bridge.menubarSetStatus(ok: true, message: message));
  }

  Future<void> _ignore(Future<Object?> future) async {
    try {
      await future;
    } catch (_) {
      // 桥不可用（如测试环境）不阻断应用。
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
