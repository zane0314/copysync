import 'package:flutter/material.dart';

import '../bridge/android_bridge_models.dart';
import '../bridge/android_host.dart';
import '../state/app_state.dart';
import 'tokens.dart';

/// 系统分享确认对话框（迁移自旧工程分享确认语义）：
/// 列出待发送内容、可选目标设备（默认同步网页/全部设备），
/// 发送或取消后都会调用 share.confirm 清理原生缓存。
class ShareConfirmDialog extends StatefulWidget {
  const ShareConfirmDialog({
    super.key,
    required this.payloads,
    required this.state,
    required this.host,
  });

  final List<AndroidSharePayload> payloads;
  final AppState state;
  final AndroidHost host;

  @override
  State<ShareConfirmDialog> createState() => _ShareConfirmDialogState();
}

class _ShareConfirmDialogState extends State<ShareConfirmDialog> {
  String _target = ''; // '' = 同步网页/全部设备
  bool _sending = false;
  String? _error;

  List<String> get _ids => [for (final p in widget.payloads) p.id];

  Future<void> _dismiss() async {
    await widget.host.shareConfirm(_ids);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    var failed = 0;
    for (final payload in widget.payloads) {
      final target = _target.isEmpty ? null : _target;
      var ok = true;
      if (payload.text != null && payload.text!.trim().isNotEmpty) {
        ok = await widget.state.sendText(payload.text!, targetDevice: target);
      }
      for (final file in payload.files) {
        final sent = file.mime.startsWith('image/')
            ? await widget.state.sendImage(file.path, targetDevice: target)
            : await widget.state.sendFile(file.path, targetDevice: target);
        ok = ok && sent;
      }
      if (!ok) failed += 1;
    }
    await widget.host.shareConfirm(_ids);
    if (!mounted) return;
    if (failed == 0) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发送')));
    } else {
      setState(() {
        _sending = false;
        _error = '$failed 项发送失败：${widget.state.sendError ?? '未知原因'}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final targets = widget.state.devices
        .where((d) => d.id != widget.state.currentDeviceId)
        .toList();
    return AlertDialog(
      key: const Key('shareConfirmDialog'),
      title: const Text('分享到 CopySync'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final payload in widget.payloads)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                _describe(payload),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textPrimary),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            key: const Key('shareTargetDropdown'),
            initialValue: _target,
            decoration: const InputDecoration(labelText: '目标设备'),
            items: [
              const DropdownMenuItem(value: '', child: Text('同步网页 / 全部设备')),
              for (final d in targets)
                DropdownMenuItem(value: d.id, child: Text(d.name)),
            ],
            onChanged: (value) => setState(() => _target = value ?? ''),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.danger)),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('shareCancelButton'),
          onPressed: _sending ? null : _dismiss,
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('shareSendButton'),
          onPressed: _sending ? null : _send,
          child: Text(_sending ? '发送中…' : '发送'),
        ),
      ],
    );
  }

  String _describe(AndroidSharePayload payload) {
    final parts = <String>[];
    if (payload.text != null && payload.text!.isNotEmpty) {
      parts.add('文本：${payload.text}');
    }
    if (payload.files.isNotEmpty) {
      parts.add('文件：${payload.files.map((f) => f.name).join('、')}');
    }
    return parts.isEmpty ? '空分享' : parts.join('\n');
  }
}
