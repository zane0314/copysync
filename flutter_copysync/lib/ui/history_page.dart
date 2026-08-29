import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import 'tokens.dart';
import 'widgets/item_tile.dart';

/// 传输历史页：定向传输条目（方向/状态/ack）与 sync 中观察到的投递。
/// v1 无投递列表/详情接口：本机创建的投递有完整字段，其他设备的投递
/// 只能从 sync 变化得知 id，渲染为占位行，ack 结果以服务端校验为准。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.state});

  final AppState state;

  static const _statusLabels = {
    'waiting': '等待接收',
    'delivered': '已确认',
    'downloaded': '已下载',
    'copied': '已复制',
    'failed': '失败',
  };

  String _deviceName(String id) => state.deviceDisplayName(id);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final transfers = state.transferItems.reversed.toList();
          final observed = state.observedDeliveryIds;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
                child: Row(
                  children: [
                    Text('传输历史',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const Spacer(),
                    ElevatedButton.icon(
                      key: const Key('historyRefreshButton'),
                      icon: const Icon(Icons.refresh, size: 17),
                      label: const Text('刷新'),
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: AppColors.primarySoft,
                        foregroundColor: AppColors.primary,
                      ),
                      onPressed:
                          state.refreshStatus == OpStatus.loading
                              ? null
                              : state.refresh,
                    ),
                  ],
                ),
              ),
              if (state.refreshStatus == OpStatus.loading)
                const LinearProgressIndicator(),
              Expanded(
                child: RefreshIndicator(
                  key: const Key('historyPullRefresh'),
                  onRefresh: state.refresh,
                  child: transfers.isEmpty && observed.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) =>
                              SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight),
                              child: const Center(
                                  child: Text('暂无传输记录',
                                      style: TextStyle(
                                          color: AppColors.textSecondary))),
                            ),
                          ),
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.xl),
                          itemCount: transfers.length + observed.length,
                          separatorBuilder: (context, index) => const Divider(
                              height: 1, color: AppColors.hairline),
                          itemBuilder: (context, index) => index <
                                  transfers.length
                              ? _transferTile(context, transfers[index])
                              : _observedTile(
                                  context, observed.elementAt(index - transfers.length)),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _transferTile(BuildContext context, Item item) {
    final isOut = item.sourceDevice == state.currentDeviceId;
    final related =
        state.deliveries.where((d) => d.itemId == item.id).toList();
    final delivery = related.isEmpty ? null : related.last;
    final status = delivery?.status ?? '';
    final direction = isOut
        ? '发出 → ${_deviceName(item.targetDevice)}'
        : '收到 ← ${_deviceName(item.sourceDevice)}';
    final ackable = delivery != null &&
        delivery.targetDevice == state.currentDeviceId &&
        delivery.status == 'waiting';
    final acking = delivery != null &&
        state.entryOp(delivery.id) == OpStatus.loading;
    final ackError =
        delivery != null ? state.entryError(delivery.id) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ItemTile(
          item: item,
          sourceLabel: state.deviceDisplayName(item.sourceDevice),
          statusText: [
            direction,
            if (_statusLabels[status] != null) _statusLabels[status]!,
          ].join(' · '),
          onEditNote: (note) async {
            final ok = await state.updateNote(item.id, note);
            return ok ? null : state.entryError(item.id) ?? '备注保存失败';
          },
          primaryAction: ackable
              ? IconButton(
                  key: Key('ack-${delivery.id}'),
                  icon: acking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline,
                          color: AppColors.primary),
                  tooltip: '确认收到',
                  onPressed: acking
                      ? null
                      : () => state.ackDelivery(delivery.id),
                )
              : null,
          menuItems: [
            PopupMenuItem(
              onTap: () => showItemDetail(context, item),
              child: const Text('查看详情'),
            ),
          ],
        ),
        if (ackError != null)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(ackError,
                style: const TextStyle(
                    color: AppColors.danger, fontSize: 12)),
          ),
      ],
    );
  }

  /// sync 中观察到但无详情的投递：只确认存在，ack 由服务端校验目标设备。
  Widget _observedTile(BuildContext context, String id) {
    final acking = state.entryOp(id) == OpStatus.loading;
    final error = state.entryError(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
          child: Row(
            children: [
              const Icon(Icons.swap_horiz, color: AppColors.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text('投递 $id（详情由服务端校验）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary)),
              ),
              TextButton.icon(
                key: Key('ack-$id'),
                onPressed:
                    acking ? null : () => state.ackDelivery(id),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(acking ? '确认中' : '确认收到'),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(error,
                style: const TextStyle(
                    color: AppColors.danger, fontSize: 12)),
          ),
      ],
    );
  }
}
