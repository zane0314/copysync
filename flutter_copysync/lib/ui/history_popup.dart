import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bridge_models.dart';
import '../state/app_state.dart';
import '../state/history_controller.dart';
import 'tokens.dart';

/// macOS 键盘优先历史浮窗：输入即搜索、↑↓ 选择、回车复制并粘贴到前一应用、
/// Esc 关闭；鼠标点击与悬浮固定同样完整。
class HistoryPopup extends StatefulWidget {
  const HistoryPopup({super.key, required this.controller});

  final HistoryController controller;

  @override
  State<HistoryPopup> createState() => _HistoryPopupState();
}

class _HistoryPopupState extends State<HistoryPopup> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  HistoryController get controller => widget.controller;

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      controller.moveSelection(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      controller.moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      controller.hide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 72),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.card),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              key: const Key('historyPopup'),
              width: 440,
              constraints: const BoxConstraints(maxHeight: 420),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(AppRadii.card),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.card,
              ),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Focus(
                        focusNode: _focusNode,
                        onKeyEvent: _onKey,
                        child: TextField(
                          key: const Key('historySearch'),
                          controller: _searchController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '搜索历史，回车粘贴',
                            prefixIcon: Icon(Icons.search),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.md),
                          ),
                          onChanged: controller.setQuery,
                          onSubmitted: (_) => controller.pasteSelected(),
                        ),
                      ),
                      const Divider(height: 1, color: AppColors.border),
                      Flexible(child: _buildList()),
                      const Divider(height: 1, color: AppColors.border),
                      _buildFooter(),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (controller.loadStatus == OpStatus.loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final items = controller.filtered;
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: Text('无匹配历史',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final selected = index == controller.selectedIndex;
        return InkWell(
          key: Key('historyItem-${item.id}'),
          onTap: () async {
            controller.selectedIndex = index;
            await controller.pasteSelected();
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: kMinTapTarget),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            color: selected ? AppColors.primarySoft : null,
            child: Row(
              children: [
                Icon(
                  item.kind == BridgeItemKind.image
                      ? Icons.image_outlined
                      : Icons.text_snippet_outlined,
                  size: 18,
                  color: item.kind == BridgeItemKind.image
                      ? AppColors.kindImage
                      : AppColors.kindText,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    item.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      child: Row(
        children: [
          IconButton(
            key: const Key('historyPinButton'),
            icon: Icon(
              controller.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              size: 18,
              color: controller.pinned
                  ? AppColors.primary
                  : AppColors.textSecondary,
            ),
            tooltip: '悬浮固定',
            onPressed: controller.togglePinned,
          ),
          if (controller.error != null)
            Expanded(
              child: Text(controller.error!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.danger, fontSize: 12)),
            )
          else
            const Spacer(),
          const Text('↑↓ 选择 · 回车粘贴 · Esc 关闭',
              style:
                  TextStyle(color: AppColors.textSecondary, fontSize: 11)),
        ],
      ),
    );
  }
}
