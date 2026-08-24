import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token 存储抽象：原生端要求系统安全存储；测试可注入内存实现。
abstract class TokenStore {
  Future<String?> read();
  Future<void> save(String token);
  Future<void> clear();
}

/// 生产实现：iOS Keychain / Android Keystore / macOS Keychain。
class SecureTokenStore implements TokenStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'copysync_v1_token';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> save(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
