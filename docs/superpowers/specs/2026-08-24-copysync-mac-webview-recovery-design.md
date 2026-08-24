# CopySync macOS WebView 自动恢复设计

## 目标

CopySync 右侧 `WKWebView` 的内容进程终止或顶层导航失败后，无需退出应用即可自动恢复。Mac 版本统一升级为 `2.2 (build 35)`，生成签名应用、DMG 和更新 ZIP，并覆盖安装到 `/Applications/CopySync.app`。

## 范围

- 修改 `mac-clipboard/CopySync.m`，补充 `WKNavigationDelegate` 恢复回调。
- 修改 `mac-clipboard/Info.plist` 为版本 `2.2`、build `35`。
- 更新 `updates/mac.json` 和 `updates/CopySync-Mac-latest.zip`。
- 复用现有 `build-dmg.sh` 和钥匙串中的 `CopySync Local Signing` 证书构建签名包。
- 覆盖安装并启动本机 `/Applications/CopySync.app`。
- 不修改网页、后端、Android 端，不部署服务器，不推送远端仓库。

## 恢复机制

在 `CopySyncApp` 中集中提供一个恢复入口，避免三个 delegate 回调重复实现加载逻辑：

1. `webViewWebContentProcessDidTerminate:` 在 WebContent 进程终止后请求恢复。
2. `didFailProvisionalNavigation:withError:` 处理页面尚未建立时的加载失败。
3. `didFailNavigation:withError:` 处理已开始提交后的导航失败。
4. `NSURLErrorCancelled` 属于正常取消，不触发恢复。
5. 同一时刻只允许一个待执行恢复任务，避免多个回调造成重复加载。
6. 恢复时重新加载固定的 `Site` URL，并继续使用忽略本地缓存的现有请求策略。
7. `didFinishNavigation:` 清除恢复状态，再执行现有 heartbeat、EventSource 和收件逻辑。

导航失败采用短延迟恢复，防止 delegate 回调栈内立即重入；WebContent 进程终止同样经过同一恢复入口。持续断网时只维持一个待重试任务，不并发创建请求。

## 错误处理

- 恢复任务执行前确认回调对应当前 `self.webView`。
- 恢复加载仍失败时由导航失败 delegate 再次进入同一去重流程。
- 不清 Cookie、不创建新 data store、不重建 WebView，保留登录态和现有原生消息桥。
- 失败信息写入现有底部状态栏，恢复成功后恢复正常状态提示。

## 验证

1. 静态检查：确认三个 delegate 回调存在，取消错误被忽略，恢复入口唯一。
2. 编译与构建：`clang`、`build-dmg.sh` 均成功退出。
3. 签名检查：`codesign --verify --deep --strict` 成功，签名身份仍为 `CopySync Local Signing`。
4. 版本检查：构建产物和覆盖安装后的应用均为 `2.2 (35)`。
5. 正常启动：主页加载，原生侧栏和网页内容均显示。
6. 故障注入：仅终止 CopySync 对应的 WebContent 进程，确认应用不退出且网页自动恢复。
7. 更新包检查：重新计算 ZIP SHA-256，`updates/mac.json` 与实际文件一致。

## 回滚

覆盖前保留当前 `/Applications/CopySync.app` 的临时备份；若构建、签名或故障注入验证失败，恢复 build 34。验证完成后再移除临时备份。
