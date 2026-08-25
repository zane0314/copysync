import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../tokens.dart';

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 相对时间：当天 HH:mm、昨天、n 天前。
String formatTime(int epochSeconds) {
  if (epochSeconds <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  if (diff == 1) return '昨天';
  return '$diff 天前';
}

/// 到期状态：图钉永久 / 已过期 / 剩余 n 天。
String formatExpiry(Item item) {
  if (item.pinned) return '永久';
  if (item.expiresAt <= 0) return '永久';
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final left = item.expiresAt - now;
  if (left <= 0) return '已过期';
  final days = left ~/ 86400;
  if (days >= 1) return '$days 天后过期';
  final hours = left ~/ 3600;
  return hours >= 1 ? '$hours 小时后过期' : '即将过期';
}

/// 统一列表行：类型图标、标题（省略号截断、点击看完整值）、来源与状态、
/// 时间与大小、主操作按钮与更多菜单；操作区不被挤出，最小点击区 44×44。
class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    this.leading,
    this.statusText,
    this.primaryAction,
    this.menuItems,
  });

  final Item item;

  /// 自定义前导（如收件箱的图片预览）；缺省为类型图标。
  final Widget? leading;

  /// 追加在"来源 x"之后的状态文本（如 等待接收 / 永久）。
  final String? statusText;

  /// 主操作（下载/复制等），为 null 则不显示。
  final Widget? primaryAction;

  /// 更多菜单项；空则不显示菜单按钮。
  final List<PopupMenuEntry<void>>? menuItems;

  String get title => item.kind == 'text' ? item.text : item.name;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading ?? _kindIcon(),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => showItemDetail(context, item),
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 14),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '来源 ${item.sourceDevice}'
                  '${statusText != null && statusText!.isNotEmpty ? ' · $statusText' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatTime(item.createdAt),
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
              Text(formatSize(item.size),
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
          ?primaryAction,
          if (menuItems case final items? when items.isNotEmpty)
            PopupMenuButton<void>(
              key: Key('more-${item.id}'),
              icon: const Icon(Icons.more_horiz,
                  color: AppColors.textSecondary),
              tooltip: '更多',
              itemBuilder: (context) => items,
            ),
        ],
      ),
    );
  }

  Widget _kindIcon() {
    final (icon, color) = switch (item.kind) {
      'image' => (Icons.image_outlined, AppColors.kindImage),
      'file' => (Icons.insert_drive_file_outlined, AppColors.kindFile),
      _ => (Icons.text_snippet_outlined, AppColors.kindText),
    };
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.tile),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}

/// 长文本完整值入口：详情弹窗（可选择复制）。
void showItemDetail(BuildContext context, Item item) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('itemDetailDialog'),
      title: Text(item.kind == 'text' ? '文本内容' : item.name),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
              item.kind == 'text' ? item.text : item.name),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 删除二次确认（危险操作必须可取消）。
Future<bool> confirmDelete(BuildContext context, String title) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认删除'),
      content: Text('将删除「$title」，此操作不可撤销。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirmDeleteButton'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
