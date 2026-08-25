import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge/native_bridge.dart';
import '../bridge/update_checker.dart';
import '../state/app_state.dart';
import '../state/history_controller.dart';
import 'drive_page.dart';
import 'history_page.dart';
import 'history_popup.dart';
import 'inbox_page.dart';
import 'settings_page.dart';
import 'tokens.dart';

/// 主壳：桌面为蓝色环境底上的毛玻璃侧栏 + 毛玻璃主面板（含历史浮窗覆盖层），
/// Android 为底部导航 + 单列内容。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.state,
    this.bridge,
    this.updater,
    this.history,
    this.desktopLayout,
  });

  final AppState state;
  final NativeBridge? bridge;
  final UpdateChecker? updater;
  final HistoryController? history;

  /// 强制桌面/移动布局（测试用）；null 时按平台判断。
  final bool? desktopLayout;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = ['收件箱', '传输历史', '临时网盘', '设置'];
  static const _icons = [
    Icons.inbox,
    Icons.history,
    Icons.cloud_outlined,
    Icons.settings,
  ];

  void _select(int index) => setState(() => _index = index);

  List<Widget> _pages() => [
        InboxPage(state: widget.state, bridge: widget.bridge),
        HistoryPage(state: widget.state),
        DrivePage(state: widget.state, bridge: widget.bridge),
        SettingsPage(
            state: widget.state,
            bridge: widget.bridge,
            updater: widget.updater),
      ];

  @override
  Widget build(BuildContext context) {
    final isAndroid = widget.desktopLayout != null
        ? !widget.desktopLayout!
        : defaultTargetPlatform == TargetPlatform.android;
    final pages = _pages();
    if (isAndroid) {
      return Scaffold(
        body: AmbientBackground(
          child: IndexedStack(index: _index, children: pages),
        ),
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _index,
          onTap: _select,
          items: [
            for (var i = 0; i < _tabs.length; i++)
              BottomNavigationBarItem(icon: Icon(_icons[i]), label: _tabs[i]),
          ],
        ),
      );
    }
    return Scaffold(
      body: AmbientBackground(
        child: Stack(
          children: [
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    GlassPanel(
                      strong: false,
                      child: _SideBar(
                        state: widget.state,
                        selected: _index,
                        onSelect: _select,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: GlassPanel(
                        child: IndexedStack(index: _index, children: pages),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.history != null)
              ListenableBuilder(
                listenable: widget.history!,
                builder: (context, _) => widget.history!.visible
                    ? HistoryPopup(controller: widget.history!)
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}

/// 蓝色环境底：浅色渐变 + 柔和光斑（对应网页 .bg-decor 与参考图背景）。
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE2ECFA), Color(0xFFF3F7FD), Color(0xFFE5EEFB)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned(
            left: -120,
            top: -160,
            child: _GlowSpot(color: Color(0x5976A5FF), size: 560),
          ),
          const Positioned(
            right: -140,
            top: -80,
            child: _GlowSpot(color: Color(0x478CBEFF), size: 520),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: -220,
            child: _GlowSpot(color: Color(0x52B0CDFA), size: 640),
          ),
          child,
        ],
      ),
    );
  }
}

class _GlowSpot extends StatelessWidget {
  const _GlowSpot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}

/// 毛玻璃面板：半透明白 + 白色描边 + 柔和投影 + 背景模糊。
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.strong = true});

  final Widget child;

  /// 主面板用更实一些的玻璃，侧栏更透。
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.panel),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          decoration: BoxDecoration(
            color: strong ? AppColors.glassStrong : AppColors.glass,
            borderRadius: BorderRadius.circular(AppRadii.panel),
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: AppShadows.panel,
          ),
          // 透明 Material 让 ListTile/Ink 效果有最近的 Material 祖先。
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// 桌面左侧栏（参考图：品牌、收件箱、传输历史、临时网盘、打开网页版、底部设置）。
class _SideBar extends StatelessWidget {
  const _SideBar({
    required this.state,
    required this.selected,
    required this.onSelect,
  });

  final AppState state;
  final int selected;
  final ValueChanged<int> onSelect;

  static const _tabs = ['收件箱', '传输历史', '临时网盘'];
  static const _icons = [Icons.inbox, Icons.history, Icons.cloud_outlined];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 244,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, AppSpacing.lg),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.primarySoft,
                    child:
                        Icon(Icons.sync, color: AppColors.primary, size: 22),
                  ),
                  SizedBox(width: AppSpacing.md - 1),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CopySync',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink,
                            letterSpacing: -0.3,
                          )),
                      Text('智能文件同步',
                          style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
            for (var i = 0; i < _tabs.length; i++)
              _navItem(
                  key: Key('nav-$i'),
                  icon: _icons[i],
                  label: _tabs[i],
                  index: i),
            _navItem(
              key: const Key('nav-open-web'),
              icon: Icons.open_in_new,
              label: '打开网页版',
              index: -1,
              onTap: _openWeb,
            ),
            const Spacer(),
            _navItem(
              key: const Key('nav-settings'),
              icon: Icons.settings,
              label: '设置',
              index: 3,
            ),
          ],
        ),
      ),
    );
  }

  void _openWeb() {
    // 桌面直接用系统浏览器打开服务端网页（避免引入 url_launcher）。
    if (Platform.isMacOS) {
      Process.run('open', [state.api.baseUrl]);
    }
  }

  Widget _navItem({
    required Key key,
    required IconData icon,
    required String label,
    required int index,
    VoidCallback? onTap,
  }) {
    final isSelected = index == selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isSelected ? AppColors.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(AppRadii.tile),
          onTap: onTap ?? () => onSelect(index),
          child: Container(
            constraints: const BoxConstraints(minHeight: kMinTapTarget),
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.md + 2),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textSecondary),
                const SizedBox(width: AppSpacing.md - 1),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textPrimary,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
