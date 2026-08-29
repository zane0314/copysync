import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token 存储抽象：原生端要求系统安全存储；测试可注入内存实现。
abstract class TokenStore {
  Future<String?> read();
  Future<void> save(String token);
  Future<void> clear();

  /// 当前设备 id（方向判断等用；与 token 同生命周期）。
  Future<String?> readDeviceId();
  Future<void> saveDeviceId(String deviceId);

  /// 服务端基址（登录成功时保存，重启后恢复；与 token 解耦——登出后仍保留，
  /// 便于下次登录预填、并避免恢复会话时回退到仅供模拟器用的默认地址）。
  Future<String?> readBaseUrl();
  Future<void> saveBaseUrl(String baseUrl);
}

/// 生产实现：iOS Keychain / Android Keystore / macOS Keychain。
class SecureTokenStore implements TokenStore {
  // useDataProtectionKeyChain: false —— 数据保护钥匙串要求 keychain-access-groups
  // 权限（需正式签名），本地开发/未签名构建会抛 PlatformException(-34018)。
  // 阶段 5 签名定案时再评估恢复。
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );
  static const _key = 'copysync_v1_token';
  static const _deviceKey = 'copysync_v1_device_id';
  static const _baseUrlKey = 'copysync_v1_base_url';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> save(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _storage.delete(key: _deviceKey);
    // baseUrl 有意保留：登出不应丢失服务端地址。
  }

  @override
  Future<String?> readDeviceId() => _storage.read(key: _deviceKey);

  @override
  Future<void> saveDeviceId(String deviceId) =>
      _storage.write(key: _deviceKey, value: deviceId);

  @override
  Future<String?> readBaseUrl() => _storage.read(key: _baseUrlKey);

  @override
  Future<void> saveBaseUrl(String baseUrl) =>
      _storage.write(key: _baseUrlKey, value: baseUrl);
}
