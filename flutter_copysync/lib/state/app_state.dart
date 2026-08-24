import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'token_store.dart';

/// 每个操作的独立状态：idle/loading/success/error。
enum OpStatus { idle, loading, success, error }

/// 单一 ChangeNotifier 状态体系：认证 + 收件箱（设备/项目/游标）。
class AppState extends ChangeNotifier {
  AppState({required this.api, required this.tokenStore});

  final ApiClient api;
  final TokenStore tokenStore;

  // ---- 认证 ----
  OpStatus loginStatus = OpStatus.idle;
  String? loginError;
  Device? device;

  bool get isLoggedIn => api.token != null;

  // ---- 收件箱 ----
  OpStatus refreshStatus = OpStatus.idle;
  String? refreshError;
  OpStatus sendStatus = OpStatus.idle;
  String? sendError;
  List<Device> devices = [];
  List<Item> items = [];
  int _cursor = 0;
  String? _pendingIdemKey;
  final _random = Random();

  int get onlineDeviceCount => devices.where((d) => d.online).length;

  Future<bool> login({
    required String password,
    required String deviceName,
    required String platform,
  }) async {
    if (loginStatus == OpStatus.loading) return false;
    loginStatus = OpStatus.loading;
    loginError = null;
    notifyListeners();
    try {
      final result = await api.login(
        password: password,
        deviceName: deviceName,
        platform: platform,
      );
      await tokenStore.save(result.token);
      device = result.device;
      loginStatus = OpStatus.success;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      loginStatus = OpStatus.error;
      loginError = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> restoreSession() async {
    final token = await tokenStore.read();
    if (token != null && token.isNotEmpty) {
      api.token = token;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await tokenStore.clear();
    api.token = null;
    device = null;
    devices = [];
    items = [];
    _cursor = 0;
    loginStatus = OpStatus.idle;
    notifyListeners();
  }

  /// 发送文本；失败保留原数据，重试复用同一幂等键。
  Future<bool> sendText(String text) async {
    if (sendStatus == OpStatus.loading) return false;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      sendStatus = OpStatus.error;
      sendError = '文本不能为空';
      notifyListeners();
      return false;
    }
    sendStatus = OpStatus.loading;
    sendError = null;
    notifyListeners();
    _pendingIdemKey ??= _newIdemKey();
    try {
      final item = await api.createTextItem(
        trimmed,
        idempotencyKey: _pendingIdemKey,
      );
      _upsertItem(item);
      _pendingIdemKey = null;
      sendStatus = OpStatus.success;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      sendStatus = OpStatus.error;
      sendError = e.message;
      notifyListeners();
      return false;
    }
  }

  /// 增量同步 + 设备列表；游标失效时回退 cursor=0 全量。
  Future<void> refresh() => _refresh(allowFullFallback: true);

  Future<void> _refresh({required bool allowFullFallback}) async {
    if (refreshStatus == OpStatus.loading) return;
    refreshStatus = OpStatus.loading;
    refreshError = null;
    notifyListeners();
    try {
      final page = await api.sync(_cursor);
      final tombstoned =
          page.tombstones.where((t) => t.entity == 'item').map((t) => t.entityId).toSet();
      items.removeWhere((i) => tombstoned.contains(i.id));
      // 每个 item 只取最新一次 upsert。
      final upserted = <String>{};
      for (final change in page.changes.reversed) {
        if (change.entity == 'item' &&
            change.op == 'upsert' &&
            !tombstoned.contains(change.entityId)) {
          upserted.add(change.entityId);
        }
      }
      for (final id in upserted) {
        try {
          _upsertItem(await api.getItem(id));
        } on ApiException {
          // 详情暂时取不到（如已过期清理），跳过不阻断整体同步。
        }
      }
      _cursor = page.nextCursor;
      devices = await api.listDevices();
      refreshStatus = OpStatus.success;
      notifyListeners();
    } on ApiException catch (e) {
      if (e.code == 'full_sync_required' && allowFullFallback) {
        _cursor = 0;
        refreshStatus = OpStatus.idle;
        await _refresh(allowFullFallback: false);
        return;
      }
      refreshStatus = OpStatus.error;
      refreshError = e.message;
      notifyListeners();
    }
  }

  void _upsertItem(Item item) {
    final index = items.indexWhere((i) => i.id == item.id);
    if (index >= 0) {
      items[index] = item;
    } else {
      items.add(item);
    }
  }

  String _newIdemKey() =>
      'csp-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
}
