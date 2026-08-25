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

/// 收件箱页（参考图结构）：标题与在线设备数、刷新、虚线上传区、
/// 发送条（目标设备、粘贴文本、选择文件、选择照片）、我的文件列表。
class InboxPage extends StatefulWidget {
  const InboxPage({super.key, required this.state, this.bridge});

  final AppState state;

  /// macOS 桥（剪贴板/落盘增强）；不可用时降级为 Flutter 内置剪贴板与临时目录。
  final NativeBridge? bridge;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  /// 目标设备 id；空串 = 所有设备。
  String _targetDevice = '';

  /// 粘贴文本操作的即时反馈（空剪贴板等）。
  String? _pasteHint;

  AppState get state => widget.state;

  Future<void> _pasteAndSend() async {
    String? text;
    final bridge = widget.bridge;
    if (bridge != null) {
      final result = await bridge.clipboardReadText();
      if (result.ok) text = result.value;
    }
    text ??= (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      setState(() => _pasteHint = '剪贴板没有可发送的文本');
      return;
    }
    setState(() => _pasteHint = null);
    await state.sendText(
      text,
      targetDevice: _targetDevice.isEmpty ? null : _targetDevice,
    );
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
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl,
                    AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('收件箱',
                              style:
                                  Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: AppSpacing.xs + 2),
                          Row(
                            children: [
                              const Icon(Icons.circle,
                                  size: 9, color: AppColors.success),
                              const SizedBox(width: AppSpacing.sm),
                              Text('${state.onlineDeviceCount} 台设备在线',
                                  style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 13)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      key: const Key('refreshButton'),
                      onPressed: refreshing ? null : state.refresh,
                      icon: refreshing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 17),
                      label: const Text('刷新'),
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: AppColors.primarySoft,
                        foregroundColor: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              _buildDropZone(sending),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl,
                    AppSpacing.xs, AppSpacing.xl, AppSpacing.xs),
                child: _buildSendBar(sending),
              ),
              if (_pasteHint != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  child: Text(_pasteHint!,
                      style: const TextStyle(
                          color: AppColors.warning, fontSize: 13)),
                ),
              if (state.sendStatus == OpStatus.error &&
                  state.sendError != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  child: Text(state.sendError!,
                      style: const TextStyle(color: AppColors.danger)),
                ),
              if (state.refreshStatus == OpStatus.error)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
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
                    AppSpacing.xl, AppSpacing.md, AppSpacing.xl, 0),
                child: Text('我的文件',
                    style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 16,
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
          horizontal: AppSpacing.xl, vertical: AppSpacing.xs),
      child: Material(
        color: AppColors.primary.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: InkWell(
          key: const Key('dropZone'),
          borderRadius: BorderRadius.circular(AppRadii.card),
          onTap: sending ? null : () => _pickAndSend(image: false),
          child: CustomPaint(
            foregroundPainter: _DashedBorderPainter(
              color: AppColors.primary.withValues(alpha: 0.35),
              radius: AppRadii.card,
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl + 6),
              child: Column(
                children: [
                  Icon(Icons.cloud_upload_outlined,
                      color: AppColors.primary, size: 34),
                  SizedBox(height: AppSpacing.xs + 2),
                  Text('拖文件到这里上传',
                      style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 2),
                  Text('支持文本、文件、照片',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 发送条：宽屏四个等高 pill，窄屏两列换行（Android 单列响应式）。
  Widget _buildSendBar(bool sending) {
    final targets =
        state.devices.where((d) => d.id != state.currentDeviceId).toList();
    final pills = <Widget>[
      _pill(
        key: const Key('targetDeviceDropdown'),
        icon: Icons.send_to_mobile_outlined,
        child: DropdownButton<String>(
          value: _targetDevice,
          underline: const SizedBox.shrink(),
          isExpanded: true,
          isDense: true,
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600),
          items: [
            const DropdownMenuItem(
                value: '',
                child: Text('发送到：所有设备',
                    overflow: TextOverflow.ellipsis)),
            for (final d in targets)
              DropdownMenuItem(
                value: d.id,
                child: Text('${d.name}${d.online ? ' · 在线' : ' · 离线'}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged:
              sending ? null : (value) => setState(() => _targetDevice = value ?? ''),
        ),
      ),
      _pillButton(
        key: const Key('pasteTextButton'),
        icon: Icons.content_paste_outlined,
        label: '粘贴文本',
        onPressed: sending ? null : _pasteAndSend,
      ),
      _pillButton(
        key: const Key('sendFileButton'),
        icon: Icons.upload_file_outlined,
        label: '选择文件',
        onPressed: sending ? null : () => _pickAndSend(image: false),
      ),
      _pillButton(
        key: const Key('sendImageButton'),
        icon: Icons.image_outlined,
        label: '选择照片',
        onPressed: sending ? null : () => _pickAndSend(image: true),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = AppSpacing.sm + 2;
        if (constraints.maxWidth >= 620) {
          return Row(
            children: [
              for (var i = 0; i < pills.length; i++) ...[
                Expanded(flex: i == 0 ? 13 : 10, child: pills[i]),
                if (i < pills.length - 1) const SizedBox(width: gap),
              ],
            ],
          );
        }
        // 窄屏（Android 单列）：目标设备独占一行，三个操作等宽一行。
        return Column(
          children: [
            pills[0],
            const SizedBox(height: gap),
            Row(
              children: [
                for (var i = 1; i < pills.length; i++) ...[
                  Expanded(child: pills[i]),
                  if (i < pills.length - 1) const SizedBox(width: gap),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  /// 发送条 pill 容器（白底 + 细描边 + 柔和投影）。
  Widget _pill({Key? key, required IconData icon, required Widget child}) {
    return Container(
      key: key,
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadii.tile),
        border: Border.all(color: AppColors.hairline),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0D2E5DB2), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: AppColors.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _pillButton({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return ElevatedButton.icon(
      key: key,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: ElevatedButton.styleFrom(
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2),
        backgroundColor: AppColors.surface.withValues(alpha: 0.8),
        foregroundColor: AppColors.textPrimary,
        disabledBackgroundColor: AppColors.surface.withValues(alpha: 0.5),
        side: const BorderSide(color: AppColors.hairline),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ).copyWith(
        // 图标着主蓝、文字保持藏青（对应参考图 pill 蓝图标 + 深色文字）。
        iconColor: const WidgetStatePropertyAll(AppColors.primary),
      ),
    );
  }

  Widget _buildList() {
    if (state.items.isEmpty) {
      // 空态也可下拉刷新（旧 Android 全局下拉语义）。
      return RefreshIndicator(
        key: const Key('pullRefresh'),
        onRefresh: state.refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const Center(
                  child: Text('暂无内容',
                      style: TextStyle(color: AppColors.textSecondary))),
            ),
          ),
        ),
      );
    }
    final items = state.items.reversed.toList();
    // 下拉刷新（旧 Android 全局下拉语义）：空态也可下拉触发 sync。
    return RefreshIndicator(
      key: const Key('pullRefresh'),
      onRefresh: state.refresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        itemCount: items.length,
        separatorBuilder: (context, index) =>
            const Divider(height: 1, color: AppColors.hairline),
        itemBuilder: (context, index) => _tileFor(items[index]),
      ),
    );
  }

  Widget _tileFor(Item item) {
    return ItemTile(
      item: item,
      leading: item.kind == 'image' ? _ImagePreview(item: item, state: state) : null,
      sourceLabel: state.deviceDisplayName(item.sourceDevice),
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
      if (state.android != null && item.kind != 'text')
        PopupMenuItem(
          key: Key('openReceived-${item.id}'),
          onTap: () => state.openReceivedItem(item),
          child: const Text('打开已接收文件'),
        ),
      if (widget.bridge != null && item.kind != 'text')
        PopupMenuItem(
          key: Key('revealReceived-${item.id}'),
          onTap: () => widget.bridge!
              .filesRevealReceived(deliveryId: item.id, name: item.name),
          child: const Text('在 Finder 中显示'),
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
    // 优先桥写剪贴板（macOS ignoreNext 语义 / Android 原生写），
    // 桥不可用降级 Flutter 内置剪贴板。
    final bridge = widget.bridge;
    if (bridge != null) {
      final result = await bridge.clipboardWrite(text: item.text);
      if (result.ok) return;
    }
    final android = state.android;
    if (android != null) {
      final result = await android.clipboardWrite(text: item.text);
      if (result.ok) return;
    }
    await Clipboard.setData(ClipboardData(text: item.text));
  }

  Future<void> _download(Item item) async {
    // Android：经 DownloadManager 入队到 Download/CopySync 并 ack
    //（旧工程下载语义；完成通知由原生下载接收器负责）。
    if (state.android != null) {
      final ok = await state.receiveItemFile(item);
      if (!ok) debugPrint('下载失败：无对应投递或入队失败');
      return;
    }
    try {
      final bytes = await state.api.downloadContent(item.id);
      final bridge = widget.bridge;
      if (bridge != null) {
        // 收到的文件按接收语义落盘（reveal 定位用）；本机发出的按 sent: 前缀转存。
        final isMine = item.sourceDevice == state.currentDeviceId;
        final saved = isMine
            ? await bridge.filesSaveSent(
                itemId: item.id, name: item.name, data: bytes)
            : await bridge.filesSaveReceived(
                deliveryId: item.id, name: item.name, data: bytes);
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

/// 参考图虚线圆角边框。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    const dashWidth = 6.0;
    const dashGap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
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
