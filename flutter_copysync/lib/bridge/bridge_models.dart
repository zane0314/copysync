/// macOS 桥接的数据模型，字段与原生侧（NSUserDefaults 历史条目等）一一对应。
library;

enum BridgeItemKind { text, image }

enum BridgeHotkey { main, history, screenshot }

/// 历史浮窗快捷键选项（迁移自 HistoryShortcutKey：⌘, / ⌥V / ⇧⌘V）。
enum HistoryShortcut { commandComma, option, commandShift }

enum BridgePermission { screenRecording, postEvent }

/// 本地历史条目（迁移自 CopySync.m 的 clipboardHistory 字典结构）。
class BridgeHistoryItem {
  const BridgeHistoryItem({
    required this.id,
    required this.kind,
    required this.text,
    this.path,
    required this.fingerprint,
    required this.created,
  });

  factory BridgeHistoryItem.fromMap(Map<Object?, Object?> map) {
    return BridgeHistoryItem(
      id: map['id'] as String? ?? '',
      kind: map['kind'] == 'image' ? BridgeItemKind.image : BridgeItemKind.text,
      text: map['text'] as String? ?? '',
      path: map['path'] as String?,
      fingerprint: map['fingerprint'] as String? ?? '',
      created: (map['created'] as num?)?.toDouble() ?? 0,
    );
  }

  final String id;
  final BridgeItemKind kind;
  final String text;

  /// 仅 image 条目有值（历史截图目录下的 PNG 路径）。
  final String? path;
  final String fingerprint;
  final double created;

  @override
  String toString() => 'BridgeHistoryItem($id, $kind, $text)';
}

/// 缓存用量（对应旧菜单栏三行：本地历史 / 历史截图 / 临时文件缓存）。
class CacheUsage {
  const CacheUsage({
    required this.historyCount,
    required this.historyLimit,
    required this.screenshotCount,
    required this.screenshotBytes,
    required this.cacheBytes,
  });

  factory CacheUsage.fromMap(Map<Object?, Object?> map) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return CacheUsage(
      historyCount: intOf('historyCount'),
      historyLimit: intOf('historyLimit'),
      screenshotCount: intOf('screenshotCount'),
      screenshotBytes: intOf('screenshotBytes'),
      cacheBytes: intOf('cacheBytes'),
    );
  }

  final int historyCount;
  final int historyLimit;
  final int screenshotCount;
  final int screenshotBytes;
  final int cacheBytes;
}

/// 更新检查结果（迁移自 checkForUpdatesInteractive 的清单解析）。
class UpdateInfo {
  const UpdateInfo({
    required this.current,
    required this.latest,
    required this.hasUpdate,
    this.notes,
    this.url,
    this.sha256,
  });

  factory UpdateInfo.fromMap(Map<Object?, Object?> map) {
    return UpdateInfo(
      current: map['current'] as String? ?? '0',
      latest: map['latest'] as String? ?? '',
      hasUpdate: map['hasUpdate'] as bool? ?? false,
      notes: map['notes'] as String?,
      url: map['url'] as String?,
      sha256: map['sha256'] as String?,
    );
  }

  final String current;
  final String latest;
  final bool hasUpdate;
  final String? notes;
  final String? url;
  final String? sha256;
}

/// 原生 → Dart 事件（clipboard.changed / history.changed /
/// hotkey.pressed / menubar.action）。
class BridgeEvent {
  const BridgeEvent(this.name, [this.arguments]);

  final String name;
  final Object? arguments;

  @override
  String toString() => 'BridgeEvent($name, $arguments)';
}
