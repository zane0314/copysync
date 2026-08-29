# Android 生产基址修复设计

## 问题

旧版升级用户已有 token，但没有后来新增的 baseUrl 存储项。Android 启动默认值仍为 Emulator 专用的 `http://10.0.2.2:15101`，因此 UI 判定已登录，刷新与上传却连接错误地址；更新检查使用独立公网 URL，所以仍可正常工作。

## 已批准方案

- 默认 API 基址改为安全占位地址；生产构建通过 `COPYSYNC_BASE_URL` 注入实际 HTTPS 地址。
- 使用编译期 `COPYSYNC_BASE_URL` 覆盖开发或 Emulator 地址。
- `restoreSession()` 保持现有“已存 baseUrl 优先”的行为。
- 不增加 build flavor、依赖或迁移表。

## 验证

- 回归测试证明未传 `dart-define` 时默认值为生产 HTTPS 地址。
- 现有登录、恢复、同步、上传测试全量回归。
- 构建下一 versionCode，并在 Emulator 从生产 28 覆盖安装后验证会话恢复请求命中生产 API。
