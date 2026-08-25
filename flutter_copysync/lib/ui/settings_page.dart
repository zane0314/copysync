import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../bridge/native_bridge.dart';
import '../bridge/update_checker.dart';
import '../state/app_state.dart';
import 'tokens.dart';
import 'widgets/item_tile.dart';

/// 设置页：设备列表（在线状态）、登录启动、缓存清理、检查更新、退出登录。
/// 桥不可用的平台显示明确降级提示，不做静默失败。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state, this.bridge, this.updater});

  final AppState state;

  /// macOS 全量桥（登录启动/缓存）；null 时对应区块降级提示。
  final NativeBridge? bridge;

  /// 检查更新能力（macOS/Android 桥均可）。
  final UpdateChecker? updater;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _loginItemEnabled;
  String? _cacheInfo;
  String? _cacheMessage;
  String? _updateMessage;
  bool _checkingUpdate = false;
  String? _updateUrl;
  String? _updateSha256;
  bool _installing = false;

  static const _macManifest = 'https://copy-direct.example.com/api/update/mac';
  static const _androidManifest =
      'https://copy-direct.example.com/updates/android.json';

  AppState get state => widget.state;

  String get _manifestUrl =>
      defaultTargetPlatform == TargetPlatform.android
          ? _androidManifest
          : _macManifest;

  @override
  void initState() {
    super.initState();
    _loadBridgeState();
  }

  Future<void> _loadBridgeState() async {
    final bridge = widget.bridge;
    if (bridge == null) return;
    final enabled = await bridge.loginItemIsEnabled();
    final usage = await bridge.cacheUsage();
    if (!mounted) return;
    setState(() {
      if (enabled.ok) _loginItemEnabled = enabled.value;
      if (usage.ok && usage.value != null) {
        final u = usage.value!;
        _cacheInfo = '历史 ${u.historyCount}/${u.historyLimit} 条 · '
            '截图 ${formatSize(u.screenshotBytes)} · 缓存 ${formatSize(u.cacheBytes)}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            children: [
              Text('设置', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle('设备'),
              ..._deviceTiles(),
              const SizedBox(height: AppSpacing.lg),
              _sectionTitle('通用'),
              _loginItemTile(),
              _cacheTile(),
              _updateTile(),
              const SizedBox(height: AppSpacing.xl),
              Center(
                child: OutlinedButton.icon(
                  key: const Key('logoutButton'),
                  onPressed: () => state.logout(),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('退出登录'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(title,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      );

  List<Widget> _deviceTiles() {
    if (state.devices.isEmpty) {
      return [
        const Text('暂无设备', style: TextStyle(color: AppColors.textSecondary)),
      ];
    }
    return [
      for (final d in state.devices)
        Container(
          key: Key('device-${d.id}'),
          margin: const EdgeInsets.only(bottom: AppSpacing.xs),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.tile),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(
                d.platform == 'android'
                    ? Icons.phone_android
                    : Icons.computer_outlined,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text('${d.name}（${d.platform}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary)),
              ),
              Icon(Icons.circle,
                  size: 8,
                  color: d.online
                      ? AppColors.success
                      : AppColors.textSecondary),
              const SizedBox(width: AppSpacing.xs),
              Text(d.online ? '在线' : '离线',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
    ];
  }

  Widget _loginItemTile() {
    final bridge = widget.bridge;
    if (bridge == null) {
      return _unsupported('登录启动', '当前平台不支持登录启动设置');
    }
    return SwitchListTile(
      key: const Key('loginItemSwitch'),
      title: const Text('登录时启动'),
      value: _loginItemEnabled ?? false,
      onChanged: (value) async {
        final result = await bridge.loginItemSet(value);
        if (!mounted) return;
        setState(() {
          if (result.ok) {
            _loginItemEnabled = value;
          } else {
            _cacheMessage = result.errorMessage ?? '登录启动设置失败';
          }
        });
      },
    );
  }

  Widget _cacheTile() {
    final bridge = widget.bridge;
    if (bridge == null) {
      return _unsupported('缓存清理', '当前平台不支持缓存清理');
    }
    return _actionTile(
      icon: Icons.cleaning_services_outlined,
      title: '缓存清理',
      subtitle: _cacheMessage ?? _cacheInfo,
      buttonKey: const Key('clearCacheButton'),
      buttonLabel: '清理缓存',
      onPressed: () async {
        final result = await bridge.cacheClear();
        if (!mounted) return;
        setState(() {
          _cacheMessage =
              result.ok ? '已清理本地历史与缓存' : (result.errorMessage ?? '清理失败');
        });
      },
    );
  }

  Widget _updateTile() {
    final updater = widget.updater;
    if (updater == null) {
      return _unsupported('检查更新', '当前平台不支持检查更新');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _actionTile(
          icon: Icons.system_update_alt,
          title: '检查更新',
          subtitle: _updateMessage,
          buttonKey: const Key('checkUpdateButton'),
          buttonLabel: _checkingUpdate ? '检查中' : '检查更新',
          onPressed: _checkingUpdate
              ? null
              : () async {
                  setState(() {
                    _checkingUpdate = true;
                    _updateMessage = null;
                  });
                  final result = await updater.updateCheck(_manifestUrl);
                  if (!mounted) return;
                  setState(() {
                    _checkingUpdate = false;
                    if (!result.ok || result.value == null) {
                      _updateMessage = result.errorMessage ?? '检查更新失败';
                      return;
                    }
                    final info = result.value!;
                    if (info.hasUpdate) {
                      _updateMessage =
                          '发现新版本 ${info.latest}（当前 ${info.current}）';
                      _updateUrl = info.url;
                      _updateSha256 = info.sha256;
                    } else {
                      _updateMessage = '已是最新版本 ${info.current}';
                      _updateUrl = null;
                      _updateSha256 = null;
                    }
                  });
                },
        ),
        if (_updateUrl != null && _updateSha256 != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('installUpdateButton'),
              onPressed: _installing
                  ? null
                  : () async {
                      setState(() => _installing = true);
                      final downloaded = await updater.updateDownload(
                          url: _updateUrl!, sha256: _updateSha256!);
                      if (downloaded.ok && downloaded.value != null) {
                        final installed =
                            await updater.updateInstall(downloaded.value!);
                        if (!mounted) return;
                        setState(() {
                          _installing = false;
                          _updateMessage = installed.ok
                              ? '更新包已就绪，按提示完成安装'
                              : (installed.errorMessage ?? '安装失败');
                        });
                      } else {
                        if (!mounted) return;
                        setState(() {
                          _installing = false;
                          _updateMessage =
                              downloaded.errorMessage ?? '下载失败';
                        });
                      }
                    },
              icon: const Icon(Icons.download, size: 18),
              label: Text(_installing ? '下载安装中' : '下载并安装'),
            ),
          ),
      ],
    );
  }

  Widget _unsupported(String title, String message) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(message,
          key: Key('unsupported-$title'),
          style: const TextStyle(color: AppColors.textSecondary)),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required Key buttonKey,
    required String buttonLabel,
    required VoidCallback? onPressed,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(color: AppColors.textPrimary)),
                if (subtitle != null)
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          TextButton(
            key: buttonKey,
            onPressed: onPressed,
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}
