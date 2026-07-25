# CopySync 问题修复需求提炼（2026-07-25）

来源：用户反馈的 7 组问题（2 张截图 + 录屏权限死循环补充说明）。
代码定位已完成，本文档只提炼需求 / 检验目标 / 约束，不含实现方案。

## 实施状态（2026-07-25 已完成并部署）

- ✅ 全部 8 项需求已实现；22 个后端测试通过、`test-source.sh` 通过、clang 编译通过
- ✅ 已部署到示例 VPS（copy-direct.example.com），Mac 更新发布为 build 34（`updates/mac.json`）
- ✅ R1 采用固定自签名证书 `CopySync Local Signing`（`mac-clipboard/signing/`，已 gitignore），DR 锚定证书，今后更新权限不再失效；`requestScreenCapturePermission` 增加一次性修复引导弹窗
- ✅ 本机 `/Applications/CopySync.app` 已换新构建，旧 TCC 记录已 `tccutil reset`，录屏权限已重新授予并实测 ⌘J 截图成功（历史悬浮贴出现「区域截图」）
- ✅ R8 按钮等高对齐、R6 侧栏「设备」移除均已截图实测确认
- Android APK 无需重发：网盘/收件箱 UI 从服务器远程加载，部署即生效

---

## 需求 1：Mac 端录屏（截图）权限死循环

**现象**：⌘J 截图 → 提示授权 → 系统设置中已授权 → 提示重启 → 重启后 preflight 仍失败 → 再次要求授权，死循环，截图功能完全不可用。且每次 App 更新后旧授权失效。

**根因（已确认）**：
- `build-dmg.sh:13` 用 ad-hoc 签名（`codesign --sign -`），每次构建 cdhash 都变；
- 自动更新整体替换 `.app`（`CopySync.m:1017`），新二进制与 TCC 旧授权记录不匹配 → `CGPreflightScreenCaptureAccess()`（`CopySync.m:861`）永远返回 NO；
- TCC 已有失效记录时 `CGRequestScreenCaptureAccess()` 不再弹系统框，只能手动去设置里删了重加 → 死循环。

**需求**：
- R1.1 修复权限检测/引导逻辑，授权后重启能正确识别"已授权"，不再死循环；
- R1.2 更新后尽量保留已授予的权限（稳定签名身份 / 固定 bundle id 与签名要求，或提供一键修复引导：自动打开设置并明确提示"先删除旧 CopySync 记录再重新勾选"）；
- R1.3 未授权时给出清晰的一次性引导，而不是每次点击都重复弹。

**检验目标**：
- 授权后重启 App，⌘J 直接可截图，不再弹授权提示；
- 覆盖安装新版本后，权限仍有效或有一步到位的修复路径；
- 未授权状态下引导文案准确、只引导一次。

---

## 需求 2：剪贴板历史浮窗高度与滚动条

**现象**：10 条历史的面板，手动把窗口拉到比 10 条内容还高，右侧仍显示滚动条。

**根因（已确认）**：`CopySync.m` 历史面板：
- `setFrameAutosaveName:@"CopySyncHistoryPanel"`（621）持久化旧尺寸，代码改初始高度不生效；
- `updateHistoryDocumentFrame`（793-803）用 `fittingSize` 估算行高，不考虑行最小高度约束（文本≥42、图片≥54，787），document 高度被低估 → 永远可滚；
- 只在 `refreshHistoryPanel` 时重算，窗口拉大后不重算；`maxSize 620x700`（620）偏小。

**需求**：
- R2.1 内容不足 10 条或窗口高度足够时，不出现垂直滚动条；
- R2.2 10 条内容应能在合理窗口高度内完整展示；
- R2.3 窗口尺寸持久化行为不被破坏（用户调过的大小仍被记住）。

**检验目标**：
- 10 条混合内容（文本+图片）在默认/拉大后的窗口中无滚动条、无内容裁切；
- 删除到 3 条时也无滚动条；
- 重启 App 后窗口保持用户上次调整的尺寸。

---

## 需求 3：收件箱「粘贴文本」失败

**现象**：Mac 端收件箱点「粘贴文本」失败。

**根因（已确认）**：前端用 `navigator.clipboard.readText()`（`app.py:410`），WKWebView 中不可用/抛 NotAllowedError → 进 catch 只显示提示，看似没反应。Mac 壳未注入原生剪贴板读取桥。

**需求**：
- R3.1 Mac 端点「粘贴文本」能把系统剪贴板文本填入输入框（走原生桥 `CopySyncNative` 或 JS 消息桥读取 NSPasteboard）；
- R3.2 读取失败时给出明确错误提示。

**检验目标**：Mac 端剪贴板有文本时点击即填入并可发送；剪贴板无文本时有友好提示。

---

## 需求 4：收件箱「选文件」点击没反应

**现象**：Mac 端收件箱点「选文件」无反应。

**根因（待实现时复核）**：`<label for="transferFiles">` 激活隐藏 input（`app.py:428-432`），WKWebView 对 `<input type=file>` 的支持取决于壳是否实现 `runOpenPanel` 代理——`CopySync.m` 的 WKWebView 未实现 `webView:runOpenPanelWithParameters:...` → 点击无反应。

**需求**：R4.1 Mac 端点「选文件」弹出 NSOpenPanel，选中后自动上传发送（保持现有"选完即发"行为）。

**检验目标**：Mac 端可正常选文件并出现在收件箱/网盘列表。

---

## 需求 5：收件箱「选照片」点击没反应

**现象/根因**：同需求 4（`transferImages` 同一机制）。

**需求**：R5.1 Mac 端点「选照片」弹出图片选择（NSOpenPanel 过滤图片类型），选中自动上传。

**检验目标**：同 R4.1，且图片类型过滤生效。

---

## 需求 6：移除左侧导航栏「设备」

**根因（已确认）**：侧栏是 Mac 原生（`CopySync.m:231-272`），「设备」按钮在 `CopySync.m:238`，其 action 滚动的 `.transfer` 元素在 Mac 壳页面不存在 → 本来就无效。

**需求**：R6.1 从 Mac 原生侧栏删除「设备」按钮及其 action。

**检验目标**：侧栏只剩 收件箱 / 传输历史 / 临时网盘 / 打开网页版（+设置），无「设备」，其余按钮功能不受影响。

---

## 需求 7：收件箱右上角新增刷新按钮

**需求**：
- R7.1 在 Mac 收件箱标题行（`app.py:426` `.mac-title-row`，flex space-between 右侧空位）加刷新按钮；
- R7.2 点击重新拉取收件箱列表（`/api/items`）与在线设备数，参考网盘页 `refreshBtn` + `refreshNow()`（`app.py:435、772-779`）；
- R7.3 刷新中有加载态反馈，样式与现有 UI 一致。

**检验目标**：点击后列表内容更新、有视觉反馈，不破坏 SSE 自动刷新。

---

## 需求 8：临时网盘操作按钮错位 + 高度不统一（Mac + APK 同源）

**现象**：「续期/复制/下载/✕」位置错乱；「下载」比「续期/复制」高一截。APK 与 Mac 端都有。

**根因（已确认）**：
- 「下载」是唯一用 `<a>` 的按钮（`app.py:845` `itemHtml`），其余是 `<button>`，`.act`（`app.py:150-153`）未统一 display/line-height/font → 高度与基线不一致；
- ≤900px 媒体查询（`app.py:265-278`）把 `.row-actions` 挤进 `grid-column:2` 并加 `margin-top:-8px; overflow:auto` → 窄屏/Android 下错位。

**需求**：
- R8.1 四个操作按钮统一高度、字号、基线、间距（建议下载也改为 button 或统一 .act 盒模型）；
- R8.2 修复窄屏/Android 下按钮行错位（去掉负 margin hack，正常流式布局）；
- R8.3 同一套 HTML/CSS 三端共用，改一处三端同时修好。

**检验目标**：Mac 壳、Android APK、纯网页三端的网盘列表中，四个按钮同行、等高、对齐，无溢出滚动条；点击功能（续期/复制/下载/删除）全部正常。

---

## 全局约束

- C1 **最小改动**：只动上述问题相关代码，不顺手重构；保持现有 UI 风格（绿色系、圆角、字号体系）。
- C2 **三端同源**：Web UI 改动在 `app.py` 内嵌模板一处完成，自动覆盖 Mac 壳、Android WebView、纯网页；不得为三端各写一份。
- C3 **不破坏现有功能**：SSE 自动刷新、传输历史、钉住、搜索、过滤 Tab、容量显示、自动更新机制均不得受影响。
- C4 **Mac 原生改动**集中在 `CopySync.m`（+ 必要时 `Info.plist` / `build-dmg.sh` 签名策略），改完需通过 `test-source.sh` 及编译验证。
- C5 **签名策略变更要谨慎**：若 R1.2 采用固定签名身份，需确认本机已有证书可用；无开发者证书时退而求其次做"稳定 ad-hoc + 一键权限修复引导"。
- C6 **后端 API 不改协议**：`/api/items`、`/api/upload` 等现有路由签名保持不变，Android/Web 旧版客户端不受影响。
- C7 **验证方式**：Web 层改动跑 `test_app.py`；Mac 层改动编译 `CopySync.m` 并人工验证截图/选文件流程；UI 对齐问题三端截图确认。
