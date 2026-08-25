import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../bridge/android_bridge_models.dart';
import '../bridge/android_host.dart';
import 'token_store.dart';

/// 每个操作的独立状态：idle/loading/success/error。
enum OpStatus { idle, loading, success, error }

/// 单一 ChangeNotifier 状态体系：认证 + 收件箱（设备/项目/游标）。
class AppState extends ChangeNotifier {
  AppState({required this.api, required this.tokenStore, this.android});

  final ApiClient api;
  final TokenStore tokenStore;

  /// Android 原生能力（通知/后台服务/下载/分享/转存）；非 Android 平台为 null。
  /// main() 在创建 AppState 后按平台注入。
  AndroidHost? android;

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

  // ---- Android ----
  /// 已发过接收通知的投递 id（避免每次 sync 重复弹通知）。
  final Set<String> notifiedDeliveryIds = {};

  /// 最近一次下载对账结果（重启恢复语义）。
  List<AndroidDownloadRecord> downloadRecords = [];

  // ---- 网盘 ----
  UsageInfo? usageInfo;

  // ---- 设置：修改密码 / 彻底清空 ----
  OpStatus passwordStatus = OpStatus.idle;
  String? passwordError;
  OpStatus clearAllStatus = OpStatus.idle;
  String? clearAllError;
  int clearAllDeleted = 0;

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

  /// 设备 id → 显示名（未知时回退 id 本身）。
  String deviceDisplayName(String id) {
    for (final d in devices) {
      if (d.id == id) return d.name;
    }
    return id;
  }

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
      _androidSessionStart();
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
      _androidSessionStart();
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
    passwordStatus = OpStatus.idle;
    passwordError = null;
    clearAllStatus = OpStatus.idle;
    clearAllError = null;
    notifiedDeliveryIds.clear();
    downloadRecords = [];
    if (android != null) _ignoreAndroid(android!.backgroundStop());
    notifyListeners();
  }

  /// 登录/恢复会话后的 Android 侧启动：前台服务保活 + 下载对账（重启恢复）。
  void _androidSessionStart() {
    final host = android;
    if (host == null) return;
    _ignoreAndroid(host.backgroundStart(mode: 'realtime'));
    _ignoreAndroid(() async {
      final result = await host.downloadReconcile();
      if (result.ok && result.value != null) {
        downloadRecords = result.value!;
        notifyListeners();
      }
    }());
  }

  Future<void> _ignoreAndroid(Future<Object?> future) async {
    try {
      await future;
    } catch (_) {
      // 桥不可用不阻断主流程。
    }
  }

  /// 收到新投递时系统通知（旧版接收通知语义）：只对本机目标且未通知过的。
  Future<void> _androidNotifyNewDeliveries() async {
    final host = android;
    final me = currentDeviceId;
    if (host == null || me == null) return;
    List<Delivery> list;
    try {
      list = await api.listDeliveries();
    } on ApiException {
      return; // 通知失败不阻断同步
    }
    for (final d in list) {
      if (d.targetDevice != me ||
          d.status != 'waiting' ||
          notifiedDeliveryIds.contains(d.id)) {
        continue;
      }
      notifiedDeliveryIds.add(d.id);
      _ignoreAndroid(host.notifyShow(
          title: 'CopySync 收到新内容', body: '来自 ${deviceDisplayName(d.sourceDevice)}', id: d.id));
    }
  }

  /// Android 接收文件：DownloadManager 入队到 Download/CopySync 并 ack
  /// （下载完成通知由原生下载接收器负责）。无对应投递时返回 false。
  Future<bool> receiveItemFile(Item item) async {
    final host = android;
    final me = currentDeviceId;
    if (host == null || me == null) return false;
    final list = await api.listDeliveries();
    Delivery? delivery;
    for (final d in list) {
      if (d.itemId == item.id && d.targetDevice == me) delivery = d;
    }
    if (delivery == null) return false;
    final enqueued = await host.downloadEnqueue(
      url: api.contentUrl(item.id),
      deliveryId: delivery.id,
      name: item.name,
      mime: item.mime,
      headers: {if (api.token != null) 'Authorization': 'Bearer ${api.token}'},
    );
    if (!enqueued.ok) return false;
    await ackDelivery(delivery.id, status: 'downloaded');
    return true;
  }

  /// 用系统查看器打开已接收文件（旧版 viewReceivedFile 语义）。
  Future<bool> openReceivedItem(Item item) async {
    final host = android;
    if (host == null) return false;
    final list = await api.listDeliveries();
    String? deliveryId;
    for (final d in list) {
      if (d.itemId == item.id) deliveryId = d.id;
    }
    final result = await host.filesOpenReceived(
        deliveryId: deliveryId, name: item.name, mime: item.mime);
    return result.ok;
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
      _androidSaveSent(item, path);
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

  /// 修改密码：成功后服务端撤销全部设备 Token（含当前），
  /// 本地随即退出登录回到登录页。
  Future<bool> changePassword(String current, String next) async {
    if (passwordStatus == OpStatus.loading) return false;
    passwordStatus = OpStatus.loading;
    passwordError = null;
    notifyListeners();
    try {
      await api.changePassword(currentPassword: current, newPassword: next);
      passwordStatus = OpStatus.success;
      notifyListeners();
      await logout(); // 服务端已撤销 token；logout 的 401 被吞掉
      return true;
    } on ApiException catch (e) {
      passwordStatus = OpStatus.error;
      passwordError = e.message;
      notifyListeners();
      return false;
    }
  }

  /// 彻底清空全部内容（含已固定）；成功后清空本地列表。
  Future<bool> clearAllItems() async {
    if (clearAllStatus == OpStatus.loading) return false;
    clearAllStatus = OpStatus.loading;
    clearAllError = null;
    notifyListeners();
    try {
      final result = await api.clearAll(idemKey: _newIdemKey());
      clearAllDeleted = (result['deleted'] as num?)?.toInt() ?? 0;
      items.clear();
      deliveries.clear();
      observedDeliveryIds.clear();
      clearAllStatus = OpStatus.success;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      clearAllStatus = OpStatus.error;
      clearAllError = e.message;
      notifyListeners();
      return false;
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
      _ignoreAndroid(_androidNotifyNewDeliveries());
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

  /// 发送成功后把已发送文件转存 Download/CopySync（旧版 sent: 前缀语义，
  /// 前缀由原生侧处理）；尽力而为，失败不影响发送结果。
  void _androidSaveSent(Item item, String path) {
    final host = android;
    if (host == null) return;
    _ignoreAndroid(() async {
      final bytes = await File(path).readAsBytes();
      await host.filesSaveSent(itemId: item.id, name: item.name, data: bytes);
    }());
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
