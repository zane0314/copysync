import 'dart:io';

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

/// 主壳：桌面为左侧栏 + 内容区（含历史浮窗覆盖层），Android 为底部导航。
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
        body: IndexedStack(index: _index, children: pages),
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
      body: Stack(
        children: [
          Row(
            children: [
              _SideBar(
                state: widget.state,
                selected: _index,
                onSelect: _select,
              ),
              const VerticalDivider(width: 1, color: AppColors.border),
              Expanded(
                child: IndexedStack(index: _index, children: pages),
              ),
            ],
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
    return Container(
      width: 232,
      color: AppColors.surface.withValues(alpha: 0.6),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.primarySoft,
                  child: Icon(Icons.sync, color: AppColors.primary, size: 20),
                ),
                SizedBox(width: AppSpacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CopySync',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                    Text('智能文件同步',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < _tabs.length; i++)
            _navItem(key: Key('nav-$i'), icon: _icons[i], label: _tabs[i], index: i),
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
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
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
                const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textSecondary),
                const SizedBox(width: AppSpacing.md),
                Text(
                  label,
                  style: TextStyle(
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
