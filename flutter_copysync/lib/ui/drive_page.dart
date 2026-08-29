import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../bridge/native_bridge.dart';
import '../state/app_state.dart';
import 'tokens.dart';
import 'widgets/item_tile.dart';

/// 临时网盘页：容量、上传、网盘条目（下载/图钉/续期/详情/删除二次确认）。
/// v1 item_json 不返回 web_visible 字段：客户端以"未指定具体目标设备"
/// 划分网盘内容（见 AppState.driveItems）。
class DrivePage extends StatefulWidget {
  const DrivePage({super.key, required this.state, this.bridge});

  final AppState state;
  final NativeBridge? bridge;

  @override
  State<DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends State<DrivePage> {
  AppState get state => widget.state;

  /// 搜索关键词与类型筛选（'' = 全部；pinned = 已固定）。
  String _query = '';
  String _kindFilter = '';

  static const _kindFilters = ['', 'text', 'file', 'image', 'pinned'];
  static const _kindLabels = ['全部', '文本', '文件', '图片', '已固定'];

  @override
  void initState() {
    super.initState();
    state.loadUsage();
  }

  Future<void> _upload() async {
    String? path;
    var cleanupPath = false;
    final android = state.android;
    if (Platform.isAndroid && android != null) {
      final result = await android.pickFile();
      if (!result.ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.errorMessage ?? '选择文件失败')),
          );
        }
        return;
      }
      path = result.value?.path;
      cleanupPath = path != null && path.isNotEmpty;
    } else {
      final file = await openFile(
        acceptedTypeGroups: [const XTypeGroup(label: '文件')],
      );
      path = file?.path;
    }
    final selectedPath = path;
    if (selectedPath == null || selectedPath.isEmpty) return; // 用户取消
    try {
      final ok = await state.sendFile(selectedPath);
      if (ok) await state.loadUsage();
    } finally {
      if (cleanupPath) {
        final pickedFile = File(selectedPath);
        try {
          await pickedFile.delete();
        } on FileSystemException {
          // 原生选择器已清理或文件已被系统回收。
        }
        try {
          await pickedFile.parent.delete();
        } on FileSystemException {
          // 父目录已清理或仍有其他文件时保留。
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final items = _filtered(state.driveItems.reversed.toList());
          final uploading = state.sendStatus == OpStatus.loading;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.xl,
                  AppSpacing.xl,
                  AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Text(
                      '临时网盘',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      key: const Key('driveRefreshButton'),
                      icon: const Icon(Icons.refresh, size: 17),
                      label: const Text('刷新'),
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: AppColors.primarySoft,
                        foregroundColor: AppColors.primary,
                      ),
                      onPressed: state.refreshStatus == OpStatus.loading
                          ? null
                          : () async {
                              await state.refresh();
                              await state.loadUsage();
                            },
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    ElevatedButton.icon(
                      key: const Key('driveUploadButton'),
                      onPressed: uploading ? null : _upload,
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text('上传'),
                    ),
                  ],
                ),
              ),
              if (state.usageInfo != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                    vertical: AppSpacing.xs,
                  ),
                  child: Text(
                    '已用 ${formatSize(state.usageInfo!.totalBytes)} / '
                    '${formatSize(state.usageInfo!.tempLimit)}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              // 搜索 + 类型筛选（与网页端同语义：本地列表过滤）。
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.xs,
                  AppSpacing.xl,
                  0,
                ),
                child: TextField(
                  key: const Key('driveSearchField'),
                  decoration: const InputDecoration(
                    hintText: '搜索文本、文件和图片',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.sm,
                  AppSpacing.xl,
                  0,
                ),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    for (var i = 0; i < _kindFilters.length; i++)
                      ChoiceChip(
                        key: Key(
                          'driveFilter-${_kindFilters[i].isEmpty ? 'all' : _kindFilters[i]}',
                        ),
                        label: Text(_kindLabels[i]),
                        selected: _kindFilter == _kindFilters[i],
                        onSelected: (_) =>
                            setState(() => _kindFilter = _kindFilters[i]),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: RefreshIndicator(
                  key: const Key('drivePullRefresh'),
                  onRefresh: state.refresh,
                  child: items.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) =>
                              SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: const Center(
                                    child: Text(
                                      '网盘为空',
                                      style: TextStyle(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                          ),
                          itemCount: items.length,
                          separatorBuilder: (context, index) => const Divider(
                            height: 1,
                            color: AppColors.hairline,
                          ),
                          itemBuilder: (context, index) =>
                              _tileFor(context, items[index]),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 应用搜索关键词与类型筛选（pinned 筛选项按图钉过滤）。
  List<Item> _filtered(List<Item> items) {
    var result = items;
    if (_kindFilter == 'pinned') {
      result = result.where((i) => i.pinned).toList();
    } else if (_kindFilter.isNotEmpty) {
      result = result.where((i) => i.kind == _kindFilter).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      result = result
          .where(
            (i) =>
                i.text.toLowerCase().contains(q) ||
                i.name.toLowerCase().contains(q),
          )
          .toList();
    }
    return result;
  }

  Widget _tileFor(BuildContext context, Item item) {
    final op = state.entryOp(item.id);
    final error = state.entryError(item.id);
    final canDownload = item.kind == 'file' || item.kind == 'image';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ItemTile(
          item: item,
          sourceLabel: state.deviceDisplayName(item.sourceDevice),
          statusText: formatExpiry(item),
          onEditNote: (note) async {
            final ok = await state.updateNote(item.id, note);
            return ok ? null : state.entryError(item.id) ?? '备注保存失败';
          },
          primaryAction: canDownload
              ? IconButton(
                  key: Key('drive-download-${item.id}'),
                  icon: op == OpStatus.loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  tooltip: '下载',
                  onPressed: op == OpStatus.loading
                      ? null
                      : () => _download(item),
                )
              : null,
          menuItems: [
            PopupMenuItem(
              onTap: () => state.setPinned(item.id, !item.pinned),
              child: Text(item.pinned ? '取消图钉' : '图钉置顶'),
            ),
            PopupMenuItem(
              onTap: () => state.renewItem(item.id),
              child: const Text('续期 7 天'),
            ),
            PopupMenuItem(
              onTap: () => showItemDetail(context, item),
              child: const Text('查看详情'),
            ),
            PopupMenuItem(
              onTap: () async {
                final title = item.kind == 'text' ? item.text : item.name;
                if (await confirmDelete(context, title)) {
                  await state.deleteItemById(item.id);
                  await state.loadUsage();
                }
              },
              child: const Text(
                '删除',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              error,
              style: const TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Future<void> _download(Item item) async {
    try {
      final bytes = await state.api.downloadContent(item.id);
      final bridge = widget.bridge;
      if (bridge != null) {
        final saved = await bridge.filesSaveSent(
          itemId: item.id,
          name: item.name,
          data: bytes,
        );
        if (saved.ok) {
          debugPrint('已保存：${saved.value}');
          return;
        }
      }
      final target = File(
        '${Directory.systemTemp.path}/copysync_${item.id}_${item.name}',
      );
      await target.writeAsBytes(bytes);
      debugPrint('已保存到临时目录：${target.path}');
    } on ApiException catch (e) {
      debugPrint('下载失败：${e.message}');
    }
  }
}
