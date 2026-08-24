import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';

/// 收件箱页：标题、在线设备数、刷新、粘贴文本输入、发送按钮、我的文件列表。
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
      itemBuilder: (context, index) => _ItemTile(item: items[index]),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.text_snippet_outlined),
      title: Text(
        item.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('来源 ${item.sourceDevice}'),
    );
  }
}
