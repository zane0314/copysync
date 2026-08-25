import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../bridge/native_bridge.dart';
import '../state/app_state.dart';
import 'tokens.dart';
import 'widgets/item_tile.dart';

/// 收件箱页：标题与在线设备数、刷新、上传区、目标设备、粘贴文本、
/// 选择文件/照片、我的文件列表（统一 ItemTile 行）。
class InboxPage extends StatefulWidget {
  const InboxPage({super.key, required this.state, this.bridge});

  final AppState state;

  /// macOS 桥（复制/落盘增强）；不可用时降级为 Flutter 内置剪贴板与临时目录。
  final NativeBridge? bridge;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final _pasteController = TextEditingController();

  /// 目标设备 id；空串 = 所有设备。
  String _targetDevice = '';

  AppState get state => widget.state;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ok = await state.sendText(
      _pasteController.text,
      targetDevice: _targetDevice.isEmpty ? null : _targetDevice,
    );
    if (ok) _pasteController.clear(); // 失败时保留输入内容
  }

  Future<void> _pickAndSend({required bool image}) async {
    final file = await openFile(
      acceptedTypeGroups: [
        if (image)
          const XTypeGroup(
            label: '图片',
            extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'],
          )
        else
          const XTypeGroup(label: '文件'),
      ],
    );
    if (file == null) return; // 用户取消
    final target = _targetDevice.isEmpty ? null : _targetDevice;
    if (image) {
      await state.sendImage(file.path, targetDevice: target);
    } else {
      await state.sendFile(file.path, targetDevice: target);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final sending = state.sendStatus == OpStatus.loading;
          final refreshing = state.refreshStatus == OpStatus.loading;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.xs),
                child: Row(
                  children: [
                    Text('收件箱',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(width: AppSpacing.md),
                    const Icon(Icons.circle,
                        size: 8, color: AppColors.success),
                    const SizedBox(width: AppSpacing.xs),
                    Text('在线设备 ${state.onlineDeviceCount}',
                        style:
                            const TextStyle(color: AppColors.textSecondary)),
                    const Spacer(),
                    IconButton(
                      key: const Key('refreshButton'),
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新',
                      onPressed: refreshing ? null : state.refresh,
                    ),
                  ],
                ),
              ),
              if (refreshing) const LinearProgressIndicator(),
              _buildDropZone(sending),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
                child: _buildTargetAndActions(sending),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
                child: TextField(
                  key: const Key('pasteField'),
                  controller: _pasteController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '粘贴或输入要发送的文本',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
                child: ElevatedButton(
                  key: const Key('sendButton'),
                  onPressed: sending ? null : _send,
                  child: sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('发送'),
                ),
              ),
              if (state.sendStatus == OpStatus.error &&
                  state.sendError != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Text(state.sendError!,
                      style: const TextStyle(color: AppColors.danger)),
                ),
              if (state.refreshStatus == OpStatus.error)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.refreshError ?? '刷新失败',
                          style: const TextStyle(color: AppColors.danger),
                        ),
                      ),
                      TextButton(
                        key: const Key('retryButton'),
                        onPressed: state.refresh,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                child: Text('我的文件',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600)),
              ),
              Expanded(child: _buildList()),
            ],
          );
        },
      ),
    );
  }

  /// 上传区（参考图虚线卡片；无拖拽插件，降级为点击选择文件）。
  Widget _buildDropZone(bool sending) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Material(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: InkWell(
          key: const Key('dropZone'),
          borderRadius: BorderRadius.circular(AppRadii.card),
          onTap: sending ? null : () => _pickAndSend(image: false),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Column(
              children: [
                Icon(Icons.cloud_upload_outlined,
                    color: AppColors.primary, size: 32),
                SizedBox(height: AppSpacing.xs),
                Text('拖文件到这里上传',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600)),
                Text('支持文本、文件、照片',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTargetAndActions(bool sending) {
    final targets =
        state.devices.where((d) => d.id != state.currentDeviceId).toList();
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          key: const Key('targetDeviceDropdown'),
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.tile),
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButton<String>(
            value: _targetDevice,
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem(value: '', child: Text('发送到：所有设备')),
              for (final d in targets)
                DropdownMenuItem(
                  value: d.id,
                  child:
                      Text('发送到：${d.name}${d.online ? ' · 在线' : ' · 离线'}'),
                ),
            ],
            onChanged: (value) =>
                setState(() => _targetDevice = value ?? ''),
          ),
        ),
        ElevatedButton.icon(
          key: const Key('sendFileButton'),
          onPressed: sending ? null : () => _pickAndSend(image: false),
          icon: const Icon(Icons.upload_file, size: 18),
          label: const Text('选择文件'),
        ),
        ElevatedButton.icon(
          key: const Key('sendImageButton'),
          onPressed: sending ? null : () => _pickAndSend(image: true),
          icon: const Icon(Icons.image_outlined, size: 18),
          label: const Text('选择照片'),
        ),
      ],
    );
  }

  Widget _buildList() {
    if (state.items.isEmpty) {
      return const Center(child: Text('暂无内容'));
    }
    final items = state.items.reversed.toList();
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) =>
          _tileFor(items[index]),
    );
  }

  Widget _tileFor(Item item) {
    return ItemTile(
      item: item,
      leading: item.kind == 'image' ? _ImagePreview(item: item, state: state) : null,
      statusText: formatExpiry(item),
      primaryAction: item.kind == 'text'
          ? IconButton(
              key: Key('copy-${item.id}'),
              icon: const Icon(Icons.copy_outlined),
              tooltip: '复制',
              onPressed: () => _copyText(item),
            )
          : IconButton(
              key: Key('downloadButton-${item.id}'),
              icon: const Icon(Icons.download_outlined),
              tooltip: '下载',
              onPressed: () => _download(item),
            ),
      menuItems: _menuFor(item),
    );
  }

  List<PopupMenuEntry<void>> _menuFor(Item item) {
    final targets =
        state.devices.where((d) => d.id != state.currentDeviceId).toList();
    return [
      for (final d in targets)
        PopupMenuItem(
          onTap: () => state.sendToDevice(item.id, d.id),
          child: Text('发送到 ${d.name}'),
        ),
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
          if (await confirmDelete(context, item.text.isNotEmpty ? item.text : item.name)) {
            await state.deleteItemById(item.id);
          }
        },
        child: const Text('删除', style: TextStyle(color: AppColors.danger)),
      ),
    ];
  }

  Future<void> _copyText(Item item) async {
    // 优先桥写剪贴板（ignoreNext 语义），桥不可用降级 Flutter 内置剪贴板。
    final bridge = widget.bridge;
    if (bridge != null) {
      final result = await bridge.clipboardWrite(text: item.text);
      if (result.ok) return;
    }
    await Clipboard.setData(ClipboardData(text: item.text));
  }

  Future<void> _download(Item item) async {
    try {
      final bytes = await state.api.downloadContent(item.id);
      final bridge = widget.bridge;
      if (bridge != null) {
        final saved = await bridge.filesSaveSent(
            itemId: item.id, name: item.name, data: bytes);
        if (saved.ok) {
          debugPrint('已保存：${saved.value}');
          return;
        }
      }
      final target = File(
          '${Directory.systemTemp.path}/copysync_${item.id}_${item.name}');
      await target.writeAsBytes(bytes);
      debugPrint('已保存到临时目录：${target.path}');
    } on ApiException catch (e) {
      debugPrint('下载失败：${e.message}');
    }
  }
}

/// 图片条目预览（占位 → 真实图片）。
class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.item, required this.state});

  final Item item;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: FutureBuilder<Uint8List>(
        future: state.api.downloadContent(item.id),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Image.memory(
              snapshot.data!,
              key: const Key('imagePreview'),
              fit: BoxFit.cover,
            );
          }
          if (snapshot.hasError) {
            return const Icon(Icons.broken_image_outlined);
          }
          return const ColoredBox(
            color: Color(0xFFE3EAF3),
            child: Center(
              child: Icon(Icons.image_outlined,
                  key: Key('imagePreviewPlaceholder')),
            ),
          );
        },
      ),
    );
  }
}
