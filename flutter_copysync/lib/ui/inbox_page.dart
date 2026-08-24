import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';

/// 收件箱页：标题、在线设备数、刷新、粘贴文本输入、发送按钮、
/// 发送文件/发送图片入口、我的文件列表（图片预览、文件下载）。
class InboxPage extends StatefulWidget {
  const InboxPage({super.key, required this.state});

  final AppState state;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final _pasteController = TextEditingController();

  AppState get state => widget.state;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ok = await state.sendText(_pasteController.text);
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
    if (image) {
      await state.sendImage(file.path);
    } else {
      await state.sendFile(file.path);
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
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Text('收件箱',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(width: 12),
                    Text('在线设备 ${state.onlineDeviceCount}'),
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
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  key: const Key('pasteField'),
                  controller: _pasteController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '粘贴或输入要发送的文本',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        key: const Key('sendFileButton'),
                        onPressed:
                            sending ? null : () => _pickAndSend(image: false),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('发送文件'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        key: const Key('sendImageButton'),
                        onPressed:
                            sending ? null : () => _pickAndSend(image: true),
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('发送图片'),
                      ),
                    ),
                  ],
                ),
              ),
              if (state.sendStatus == OpStatus.error &&
                  state.sendError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(state.sendError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (state.refreshStatus == OpStatus.error)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.refreshError ?? '刷新失败',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error),
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
              Expanded(child: _buildList()),
            ],
          );
        },
      ),
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
          _ItemTile(item: items[index], state: state),
    );
  }
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.state});

  final Item item;
  final AppState state;

  Future<void> _download() async {
    try {
      final bytes = await state.api.downloadContent(item.id);
      final target = File(
          '${Directory.systemTemp.path}/copysync_${item.id}_${item.name}');
      await target.writeAsBytes(bytes);
      debugPrint('已保存到临时目录：${target.path}'); // 打开/揭示为后续桥接任务
    } on ApiException catch (e) {
      debugPrint('下载失败：${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canDownload = item.kind == 'file' || item.kind == 'image';
    return ListTile(
      leading: _buildLeading(),
      title: Text(
        item.kind == 'text' ? item.text : item.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        item.kind == 'text'
            ? '来源 ${item.sourceDevice}'
            : '${formatSize(item.size)} · 来源 ${item.sourceDevice}',
      ),
      trailing: canDownload
          ? IconButton(
              key: Key('downloadButton-${item.id}'),
              icon: const Icon(Icons.download_outlined),
              tooltip: '下载',
              onPressed: _download,
            )
          : null,
    );
  }

  Widget _buildLeading() {
    switch (item.kind) {
      case 'image':
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
      case 'file':
        return const Icon(Icons.insert_drive_file_outlined);
      default:
        return const Icon(Icons.text_snippet_outlined);
    }
  }
}
