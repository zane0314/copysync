import 'package:copysync/state/token_store.dart';

/// 测试用内存实现；生产实现见 [SecureTokenStore]。
class MemoryTokenStore implements TokenStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> save(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}
