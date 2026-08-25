/// 桥接统一返回类型：禁止静默失败，任何原生错误都必须落到
/// [errorCode]/[errorMessage]（接口锁定见实施计划 Task 21）。
class BridgeResult<T> {
  const BridgeResult.success(this.value)
      : ok = true,
        errorCode = null,
        errorMessage = null;

  const BridgeResult.failure({required this.errorCode, this.errorMessage})
      : ok = false,
        value = null;

  final bool ok;
  final T? value;
  final String? errorCode;
  final String? errorMessage;

  @override
  String toString() => ok
      ? 'BridgeResult.ok($value)'
      : 'BridgeResult.fail($errorCode: $errorMessage)';
}

/// 原生侧约定的错误码（Swift 侧 PlatformException.code 必须一致）。
abstract final class BridgeErrorCodes {
  static const permissionDenied = 'permission_denied';
  static const cancelled = 'cancelled';
  static const notFound = 'not_found';
  static const notReady = 'not_ready';
  static const checksumMismatch = 'checksum_mismatch';
  static const hotkeyFailed = 'hotkey_failed';
  static const invalidArgs = 'invalid_args';
  static const systemError = 'system_error';

  /// 原生桥未注册（MissingPluginException）或系统版本不支持。
  static const unavailable = 'unavailable';
}
