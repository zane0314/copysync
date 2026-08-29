import 'dart:convert';
import 'dart:typed_data';

import 'package:copysync/bridge/bridge_models.dart';
import 'package:copysync/bridge/macos_native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// macOS 桥接冒烟：不经 mock，直接走 MethodChannel → Swift HistoryStore / BridgePaths。
/// 覆盖基线矩阵 Mac「去重」（SHA-256 指纹去重 + 置顶）与「缓存目录」（cache.usage 计数）
/// 两个此前仅有桥调用、缺行为断言的自动测试单元。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 任意非空字节即可触发 addImage 落盘与指纹计算（Swift 侧不解析 PNG 格式）；
  // 这里用 1x1 合法 PNG。
  final png = Uint8List.fromList(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));

  testWidgets('history.addText 相同内容按 SHA-256 指纹去重并置顶', (tester) async {
    final bridge = MacosNativeBridge();
    expect((await bridge.historyClear()).ok, isTrue);

    final a1 = await bridge.historyAddText('dedupe-同内容');
    expect(a1.ok, isTrue, reason: a1.errorMessage);
    final a2 = await bridge.historyAddText('dedupe-同内容');
    expect(a2.ok, isTrue, reason: a2.errorMessage);

    var list = (await bridge.historyList()).value!;
    expect(list.where((e) => e.text == 'dedupe-同内容').length, 1,
        reason: '相同内容应被指纹去重为 1 条');

    // 加入另一条内容后应置顶
    expect((await bridge.historyAddText('dedupe-新内容')).ok, isTrue);
    list = (await bridge.historyList()).value!;
    expect(list.first.text, 'dedupe-新内容', reason: '最新加入的条目应置顶');

    // 再次加入旧内容：removeAll 去重后 insert(0)，应去重且重新置顶
    expect((await bridge.historyAddText('dedupe-同内容')).ok, isTrue);
    list = (await bridge.historyList()).value!;
    expect(list.first.text, 'dedupe-同内容', reason: '重复加入旧内容应去重并重新置顶');
    expect(list.where((e) => e.text == 'dedupe-同内容').length, 1);

    await bridge.historyClear();
  });

  testWidgets('history.addImage 相同字节按指纹去重', (tester) async {
    final bridge = MacosNativeBridge();
    expect((await bridge.historyClear()).ok, isTrue);

    final i1 = await bridge.historyAddImage(png, title: '去重图片');
    expect(i1.ok, isTrue, reason: i1.errorMessage);
    final i2 = await bridge.historyAddImage(png, title: '去重图片');
    expect(i2.ok, isTrue, reason: i2.errorMessage);

    final images = (await bridge.historyList())
        .value!
        .where((e) => e.kind == BridgeItemKind.image)
        .toList();
    expect(images.length, 1, reason: '相同图片字节应被指纹去重为 1 条');
    expect(images.first.fingerprint, i1.value!.fingerprint);

    await bridge.historyClear();
  });

  testWidgets('cache.usage 反映历史上限与截图计数', (tester) async {
    final bridge = MacosNativeBridge();
    expect((await bridge.historyClear()).ok, isTrue);

    var usage = (await bridge.cacheUsage()).value!;
    expect(usage.historyLimit, 10, reason: '历史上限为 10 条（CopySync.m 语义）');
    expect(usage.historyCount, 0, reason: '清空后历史计数为 0');

    expect((await bridge.historyAddImage(png, title: '用量图片')).ok, isTrue);
    usage = (await bridge.cacheUsage()).value!;
    expect(usage.historyCount, 1);
    expect(usage.screenshotCount, greaterThanOrEqualTo(1),
        reason: '图片历史应计入截图数量');
    expect(usage.cacheBytes, greaterThanOrEqualTo(0));

    await bridge.historyClear();
  });
}
