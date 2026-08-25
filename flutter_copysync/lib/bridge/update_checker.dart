import 'bridge_models.dart';
import 'bridge_result.dart';

/// 检查/下载/安装更新能力（macOS 与 Android 桥共同实现，方法签名一致）。
abstract interface class UpdateChecker {
  Future<BridgeResult<UpdateInfo>> updateCheck(String manifestUrl);
  Future<BridgeResult<String>> updateDownload(
      {required String url, required String sha256});
  Future<BridgeResult<void>> updateInstall(String path);
}
