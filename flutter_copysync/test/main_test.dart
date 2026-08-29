import 'package:copysync/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('生产构建默认连接公网 API', () {
    expect(app.defaultBaseUrl, 'https://copy.example.com');
  });
}
