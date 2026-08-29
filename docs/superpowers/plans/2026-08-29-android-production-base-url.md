# Android Production Base URL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让旧 token、无已存 baseUrl 的 Android 升级用户默认连接 CopySync 生产 API。

**Architecture:** `main.dart` 暴露一个编译期常量，默认取生产 HTTPS 地址；开发环境使用 `--dart-define=COPYSYNC_BASE_URL=...` 覆盖。现有 TokenStore 优先恢复已存地址，不改变登录和同步协议。

**Tech Stack:** Flutter、Dart、flutter_test

## Global Constraints

- 不新增依赖或 build flavor。
- 不覆盖用户已保存的非空 baseUrl。
- 发布必须提高 Android versionCode。

---

### Task 1: 修复生产默认 API 基址

**Files:**
- Modify: `flutter_copysync/lib/main.dart`
- Create: `flutter_copysync/test/main_test.dart`

**Interfaces:**
- Produces: `defaultBaseUrl` 编译期常量，供 `main()` 创建 `ApiClient`。

- [x] **Step 1: 写失败测试**

```dart
import 'package:copysync/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('生产构建默认连接公网 API', () {
    expect(app.defaultBaseUrl, 'https://copy-direct.example.com');
  });
}
```

- [x] **Step 2: 验证 RED**

运行：`flutter test test/main_test.dart`

预期：因 `defaultBaseUrl` 尚不存在而编译失败。

- [x] **Step 3: 最小实现**

```dart
const defaultBaseUrl = String.fromEnvironment(
  'COPYSYNC_BASE_URL',
  defaultValue: 'https://copy-direct.example.com',
);
```

让 `main()` 使用该常量创建 `ApiClient`，删除平台 localhost 默认分支。

- [x] **Step 4: 验证 GREEN 与回归**

运行：`flutter test test/main_test.dart`、`flutter test --concurrency=1`、`flutter analyze`。

- [x] **Step 5: 发布验证**

版本提升到 `2.0.3+29`，构建 release APK；验证包名、版本、签名、SHA、28→29 覆盖升级以及生产公网 manifest/APK 回读。
