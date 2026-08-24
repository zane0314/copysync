import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'inbox_page.dart';

/// 主壳：Android 用底部导航骨架（非收件箱 tab 阶段 4 实现），桌面直接显示收件箱。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

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

  @override
  Widget build(BuildContext context) {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final body = _index == 0
        ? InboxPage(state: widget.state)
        : const Center(child: Text('阶段 4 实现'));
    if (!isAndroid) {
      return Scaffold(body: InboxPage(state: widget.state));
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: [
          for (var i = 0; i < _tabs.length; i++)
            BottomNavigationBarItem(icon: Icon(_icons[i]), label: _tabs[i]),
        ],
      ),
    );
  }
}
