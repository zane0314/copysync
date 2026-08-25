import 'dart:io';

import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'bridge/android_native_bridge.dart';
import 'bridge/macos_native_bridge.dart';
import 'bridge/native_bridge.dart';
import 'bridge/update_checker.dart';
import 'state/app_state.dart';
import 'state/history_controller.dart';
import 'state/menu_coordinator.dart';
import 'state/token_store.dart';
import 'ui/home_shell.dart';
import 'ui/login_page.dart';
import 'ui/theme.dart';

void main() {
  // restoreSession 会走方法通道读 Keychain，必须先初始化绑定。
  WidgetsFlutterBinding.ensureInitialized();
  final baseUrl =
      Platform.isAndroid ? 'http://10.0.2.2:15101' : 'http://127.0.0.1:15101';
  final state = AppState(
    api: ApiClient(baseUrl),
    tokenStore: SecureTokenStore(),
  );

  // 平台桥：macOS 全量桥 + 历史浮窗 + 菜单栏动作协调；Android 桥提供更新检查等能力。
  NativeBridge? bridge;
  UpdateChecker? updater;
  HistoryController? history;
  MenuCoordinator? menu;
  if (Platform.isMacOS) {
    final macBridge = MacosNativeBridge();
    bridge = macBridge;
    updater = macBridge;
    history = HistoryController(bridge: macBridge)..start();
    menu = MenuCoordinator(bridge: macBridge, history: history)..start();
  } else if (Platform.isAndroid) {
    final androidBridge = AndroidNativeBridge();
    updater = androidBridge;
    state.android = androidBridge;
  }

  state.restoreSession();
  runApp(CopySyncApp(
    state: state,
    bridge: bridge,
    updater: updater,
    history: history,
    menu: menu,
  ));
}

class CopySyncApp extends StatelessWidget {
  const CopySyncApp({
    super.key,
    required this.state,
    this.bridge,
    this.updater,
    this.history,
    this.menu,
    this.desktopLayout,
  });

  final AppState state;
  final NativeBridge? bridge;
  final UpdateChecker? updater;
  final HistoryController? history;
  final MenuCoordinator? menu;

  /// 强制桌面/移动布局（测试用）；null 时按平台判断。
  final bool? desktopLayout;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CopySync',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) => state.isLoggedIn
            ? HomeShell(
                state: state,
                bridge: bridge,
                updater: updater,
                history: history,
                menu: menu,
                desktopLayout: desktopLayout,
              )
            : LoginPage(state: state),
      ),
    );
  }
}
