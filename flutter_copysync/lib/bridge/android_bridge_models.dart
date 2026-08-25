/// Android 桥接的数据模型，字段与原生侧（Kotlin）返回的 map 一一对应。
library;

/// 分享进来的单个文件/图片：原生侧已把内容复制到应用缓存目录，
/// [path] 可直接读取上传，`share.confirm` 后由原生侧清理。
class AndroidSharedFile {
  const AndroidSharedFile({
    required this.name,
    required this.mime,
    required this.path,
    required this.size,
  });

  factory AndroidSharedFile.fromMap(Map<Object?, Object?> map) {
    return AndroidSharedFile(
      name: map['name'] as String? ?? '',
      mime: map['mime'] as String? ?? 'application/octet-stream',
      path: map['path'] as String? ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }

  final String name;
  final String mime;
  final String path;
  final int size;

  @override
  String toString() => 'AndroidSharedFile($name, $mime, $size)';
}

/// 一次分享（ACTION_SEND / SEND_MULTIPLE）的待确认载荷。
class AndroidSharePayload {
  const AndroidSharePayload({required this.id, this.text, this.files = const []});

  factory AndroidSharePayload.fromMap(Map<Object?, Object?> map) {
    return AndroidSharePayload(
      id: map['id'] as String? ?? '',
      text: map['text'] as String?,
      files: (map['files'] as List<Object?>? ?? const [])
          .map((e) => AndroidSharedFile.fromMap(e as Map<Object?, Object?>))
          .toList(),
    );
  }

  final String id;
  final String? text;
  final List<AndroidSharedFile> files;

  @override
  String toString() => 'AndroidSharePayload($id, text=$text, ${files.length} files)';
}

/// 下载对账状态（迁移自旧工程 localFileState/reconcilePendingDownloads 语义）。
enum AndroidDownloadState { ready, pending, failed, missing }

/// 一条待对账下载的结果。
class AndroidDownloadRecord {
  const AndroidDownloadRecord({
    required this.deliveryId,
    required this.name,
    required this.state,
  });

  factory AndroidDownloadRecord.fromMap(Map<Object?, Object?> map) {
    final raw = map['state'] as String? ?? 'missing';
    final state = AndroidDownloadState.values.asNameMap()[raw] ??
        AndroidDownloadState.missing;
    return AndroidDownloadRecord(
      deliveryId: map['deliveryId'] as String? ?? '',
      name: map['name'] as String? ?? '',
      state: state,
    );
  }

  final String deliveryId;
  final String name;
  final AndroidDownloadState state;

  @override
  String toString() => 'AndroidDownloadRecord($deliveryId, $name, $state)';
}
