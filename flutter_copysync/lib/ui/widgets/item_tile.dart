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
    this.sourceLabel,
    this.statusText,
    this.primaryAction,
    this.menuItems,
    this.onEditNote,
  });

  final Item item;

  /// 自定义前导（如收件箱的图片预览）；缺省为类型图标。
  final Widget? leading;

  /// 来源设备显示名（缺省为 item.sourceDevice 原始 id）。
  final String? sourceLabel;

  /// 追加在"来源 x"之后的状态文本（如 等待接收 / 永久）。
  final String? statusText;

  /// 主操作（下载/复制等），为 null 则不显示。
  final Widget? primaryAction;

  /// 更多菜单项；空则不显示菜单按钮。
  final List<PopupMenuEntry<void>>? menuItems;

  /// 返回 null 表示保存成功，否则返回可显示的失败原因。
  final Future<String?> Function(String note)? onEditNote;

  String get title => item.kind == 'text' ? item.text : item.name;

  @override
  Widget build(BuildContext context) {
    final entries = <PopupMenuEntry<void>>[
      if (onEditNote != null)
        PopupMenuItem<void>(
          key: Key('editNote-${item.id}'),
          onTap: () => editItemNote(context, item, onEditNote!),
          child: const Text('备注'),
        ),
      ...?menuItems,
    ];
    // 参考图行样式：透明底、行间由页面级 hairline 分隔，操作区不被挤出。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '来源 ${sourceLabel ?? item.sourceDevice}'
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
          if (entries.isNotEmpty)
            PopupMenuButton<void>(
              key: Key('more-${item.id}'),
              icon: const Icon(Icons.more_horiz,
                  color: AppColors.textSecondary),
              tooltip: '更多',
              itemBuilder: (context) => entries,
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

/// 条目备注编辑：保持菜单/对话框模式，并在对话框内显示保存中与失败重试。
Future<void> editItemNote(
  BuildContext context,
  Item item,
  Future<String?> Function(String note) save,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _NoteDialog(item: item, save: save),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('备注已保存')),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.item, required this.save});

  final Item item;
  final Future<String?> Function(String note) save;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _controller;
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.note);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final message = await widget.save(_controller.text.trim());
    if (!mounted) return;
    if (message == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: Key('noteDialog-${widget.item.id}'),
      title: const Text('编辑备注'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: Key('noteField-${widget.item.id}'),
            controller: _controller,
            maxLength: 200,
            autofocus: true,
            decoration: const InputDecoration(hintText: '备注（200 字以内）'),
          ),
          if (_error != null)
            Text(_error!,
                key: Key('noteError-${widget.item.id}'),
                style: const TextStyle(color: AppColors.danger)),
        ],
      ),
      actions: [
        TextButton(
          onPressed:
              _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: Key('saveNote-${widget.item.id}'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
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
