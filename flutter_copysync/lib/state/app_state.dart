import 'dart:io';
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

  /// 重启后经 restoreSession 恢复的设备 id（device 对象本身不持久化）。
  String? restoredDeviceId;

  bool get isLoggedIn => api.token != null;

  /// 当前设备 id：登录态取 device，重启恢复后取 restoredDeviceId。
  String? get currentDeviceId => device?.id ?? restoredDeviceId;

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

  // ---- 传输历史 ----
  /// 本机已知详情的投递（createDelivery/ackDelivery 返回）。
  List<Delivery> deliveries = [];

  /// sync 中观察到但本地无详情的投递 id（v1 无投递详情接口，
  /// 仅能确认存在与变化时间）。
  List<String> observedDeliveryIds = [];

  // ---- 网盘 ----
  UsageInfo? usageInfo;

  /// 按条目 id 的局部操作状态（续期/删除/图钉/定向发送/下载等）。
  final Map<String, OpStatus> _entryOps = {};
  final Map<String, String?> _entryErrors = {};

  OpStatus entryOp(String id) => _entryOps[id] ?? OpStatus.idle;
  String? entryError(String id) => _entryErrors[id];

  /// 临时网盘条目：未指定具体目标设备的内容（v1 item_json 不返回
  /// web_visible 字段，客户端以 target_device 区分网盘与定向传输）。
  List<Item> get driveItems => items
      .where((i) => i.targetDevice.isEmpty || i.targetDevice == 'all')
      .toList();

  /// 定向传输条目。
  List<Item> get transferItems => items
      .where((i) => i.targetDevice.isNotEmpty && i.targetDevice != 'all')
      .toList();

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
      await tokenStore.saveDeviceId(result.device.id);
      device = result.device;
      restoredDeviceId = result.device.id;
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
      restoredDeviceId = await tokenStore.readDeviceId();
      notifyListeners();
    }
  }

  Future<void> logout() async {
    try {
      await api.logout(); // 尽力撤销服务端 token；失败仍清本地。
    } on ApiException {
      // 网络失败不阻塞本地退出。
    }
    await tokenStore.clear();
    api.token = null;
    device = null;
    restoredDeviceId = null;
    devices = [];
    items = [];
    deliveries = [];
    observedDeliveryIds = [];
    usageInfo = null;
    _entryOps.clear();
    _entryErrors.clear();
    _cursor = 0;
    loginStatus = OpStatus.idle;
    notifyListeners();
  }

  /// 发送文本；失败保留原数据，重试复用同一幂等键。
  Future<bool> sendText(String text, {String? targetDevice}) async {
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
        targetDevice: targetDevice,
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

  /// 发送文件；失败保留幂等键，重试复用同一键。
  Future<bool> sendFile(String path, {String? targetDevice}) =>
      _sendUpload(path, targetDevice: targetDevice);

  /// 发送图片；同一图片文件同时作为 clipboard 变体上传
  ///（原生剪贴板格式转换为后续桥接任务）。
  Future<bool> sendImage(String path, {String? targetDevice}) =>
      _sendUpload(path, clipboardVariantPath: path, targetDevice: targetDevice);

  Future<bool> _sendUpload(
    String path, {
    String? clipboardVariantPath,
    String? targetDevice,
  }) async {
    if (sendStatus == OpStatus.loading) return false;
    if (!File(path).existsSync()) {
      sendStatus = OpStatus.error;
      sendError = '文件不存在：$path';
      notifyListeners();
      return false;
    }
    sendStatus = OpStatus.loading;
    sendError = null;
    notifyListeners();
    _pendingIdemKey ??= _newIdemKey();
    try {
      final item = await api.uploadFile(
        path,
        clipboardVariantPath: clipboardVariantPath,
        targetDevice: targetDevice,
        idemKey: _pendingIdemKey,
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
  /// 对已有条目定向发送到目标设备（按条目防重）。
  Future<bool> sendToDevice(String itemId, String targetDevice) =>
      _entryCall(itemId, () async {
        final delivery = await api.createDelivery(itemId,
            targetDevice: targetDevice, idemKey: _newIdemKey());
        _upsertDelivery(delivery);
      });

  /// 收件确认，更新本地投递状态。
  Future<bool> ackDelivery(String deliveryId,
          {String status = 'delivered'}) =>
      _entryCall(deliveryId, () async {
        final delivery =
            await api.ackDelivery(deliveryId, status: status, idemKey: _newIdemKey());
        _upsertDelivery(delivery);
      });

  /// 续期 7 天（服务端 clamp 上限）。
  Future<bool> renewItem(String id) => _entryCall(id, () async {
        _upsertItem(await api.patchItem(id, ttl: 7 * 86400, idemKey: _newIdemKey()));
      });

  /// 删除条目；失败保留原数据。
  Future<bool> deleteItemById(String id) => _entryCall(id, () async {
        await api.deleteItem(id, idemKey: _newIdemKey());
        items.removeWhere((i) => i.id == id);
      });

  /// 图钉开关（置顶后永久保留）。
  Future<bool> setPinned(String id, bool pinned) => _entryCall(id, () async {
        _upsertItem(await api.patchItem(id, pinned: pinned, idemKey: _newIdemKey()));
      });

  /// 拉取容量与限制。
  Future<void> loadUsage() async {
    try {
      usageInfo = await api.usage();
      notifyListeners();
    } on ApiException {
      // 容量展示失败不阻塞页面；保持旧值。
    }
  }

  /// 条目级操作模板：防重 + idle/loading/success/error + 错误消息。
  Future<bool> _entryCall(String id, Future<void> Function() action) async {
    if (entryOp(id) == OpStatus.loading) return false;
    _entryOps[id] = OpStatus.loading;
    _entryErrors[id] = null;
    notifyListeners();
    try {
      await action();
      _entryOps[id] = OpStatus.success;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _entryOps[id] = OpStatus.error;
      _entryErrors[id] = e.message;
      notifyListeners();
      return false;
    }
  }

  void _upsertDelivery(Delivery delivery) {
    final index = deliveries.indexWhere((d) => d.id == delivery.id);
    if (index >= 0) {
      deliveries[index] = delivery;
    } else {
      deliveries.add(delivery);
    }
    observedDeliveryIds.remove(delivery.id);
  }

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
      // 收集投递变化：v1 无投递详情接口，本地未知详情的只记录 id。
      final knownDeliveryIds = deliveries.map((d) => d.id).toSet();
      for (final change in page.changes) {
        if (change.entity == 'delivery' &&
            change.op == 'upsert' &&
            !knownDeliveryIds.contains(change.entityId) &&
            !observedDeliveryIds.contains(change.entityId)) {
          observedDeliveryIds.add(change.entityId);
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
