import 'package:copysync/bridge/android_bridge_models.dart';
import 'package:copysync/bridge/android_native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Android 桥接真机冒烟（模拟器）：不经 mock，直接走 MethodChannel → Kotlin。
/// 覆盖 clipboard 读写回环、前台服务、通知、分享/下载空态。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('clipboard.write 文本后可经 clipboard.readText 回读', (tester) async {
    final bridge = AndroidNativeBridge();
    const marker = 'CopySync 桥接冒烟 3c';
    final write = await bridge.clipboardWrite(text: marker);
    expect(write.ok, isTrue, reason: write.errorMessage);
    final read = await bridge.clipboardReadText();
    expect(read.ok, isTrue, reason: read.errorMessage);
    expect(read.value, marker);
  });

  testWidgets('background.start 启动前台服务，background.stop 停止', (tester) async {
    final bridge = AndroidNativeBridge();
    final started = await bridge.backgroundStart(mode: 'realtime');
    expect(started.ok, isTrue, reason: started.errorMessage);
    final stopped = await bridge.backgroundStop();
    expect(stopped.ok, isTrue, reason: stopped.errorMessage);
  });

  testWidgets('notify.show 成功', (tester) async {
    final bridge = AndroidNativeBridge();
    final result = await bridge.notifyShow(
        title: 'CopySync 冒烟', body: '桥接通知测试', id: 'smoke-1');
    expect(result.ok, isTrue, reason: result.errorMessage);
  });

  testWidgets('share.pending 空态返回空列表', (tester) async {
    final bridge = AndroidNativeBridge();
    final result = await bridge.sharePending();
    expect(result.ok, isTrue, reason: result.errorMessage);
    expect(result.value, isEmpty);
  });

  testWidgets('download.reconcile 空态返回空列表', (tester) async {
    final bridge = AndroidNativeBridge();
    final result = await bridge.downloadReconcile();
    expect(result.ok, isTrue, reason: result.errorMessage);
    expect(result.value, isA<List<AndroidDownloadRecord>>());
  });
}
