# CopySync V3 基线功能矩阵（阶段 1 冻结）

> 依据主设计 §9 逐行展开。列含义：旧入口 = 当前实现锚点（文件:行号/路由）；V3 去向 = 新页面/桥接/API；自动测试与 GUI 结果在对应阶段回填真实证据，缺失即阻止发布。

## 通用（服务端 + 全端）

| 能力 | 旧入口 | V3 去向 | 自动测试 | GUI 结果 |
|---|---|---|---|---|
| 登录 | `app.py:1450` `POST /api/login` | `POST /api/v1/auth/login`（设备独立 Token） | 阶段2 Task 8 | 待阶段4/5 |
| 退出 | `app.py:1472` `POST /api/logout` | `POST /api/v1/auth/logout`（撤销 Token） | 阶段2 Task 9 | 待阶段4/5 |
| 修改密码 | `app.py:1478` `POST /api/password` | 设置页 → 既有路由（保留）+ 全设备 Token 失效 | 待阶段2补 | 待阶段4/5 |
| 设备名称 | `devices` 表 `app.py:914-920` | `PATCH /api/v1/devices/{id}` | 阶段2 Task 9 | 待阶段4/5 |
| 在线状态 | 心跳 `app.py:1720` + `last_seen_at` | `POST /api/v1/devices/{id}/heartbeat`（路径=Token） | 阶段2 Task 9 | 待阶段4/5 |
| 定向发送 | `app.py:1695` `send_existing_item` + `create_delivery:1248` | `POST /api/v1/items/{id}/deliveries` | 阶段2 Task 17 | 待阶段4/5 |
| 文本上传 | `app.py:1629` `add_text` | `POST /api/v1/items`（JSON） | 阶段2 Task 14 | 待阶段4/5 |
| 文件上传 | `app.py:1649` `upload`（.part 原子 1677-1680） | `POST /api/v1/items`（multipart） | 阶段2 Task 14 | 待阶段4/5 |
| 照片上传 | 同文件上传 + 浏览器 canvas 转 PNG（内嵌 JS） | multipart + `clipboard_variant` 双变体 | 阶段2 Task 15 | 待阶段4/5 |
| 收件确认 | `app.py:1706` `ack_delivery` | `POST /api/v1/deliveries/{id}/ack` | 阶段2 Task 17 | 待阶段4/5 |
| 30 天传输历史 | `transfer_history` 表 `app.py:933-948`、`list_transfers:1536` | 复用表 + `/api/v1/sync` 增量 | 阶段2 Task 11 | 待阶段4/5 |
| 临时网盘 | `list_items:1514` + TTL 57-60 | `/api/v1/items` + 过期规则不变 | 阶段2 Task 14/16 | 待阶段4/5 |
| 搜索 | 内嵌 JS 前端过滤 | Flutter/Web 列表过滤（同语义） | 阶段4 | 待阶段4/5 |
| 类型筛选 | 内嵌 JS 前端过滤 | 同上 | 阶段4 | 待阶段4/5 |
| 图钉 | `app.py:1727` `toggle_pin`（PINNED_LIMIT 1731-1733） | `PATCH /api/v1/items/{id}` | 阶段2 Task 16 | 待阶段4/5 |
| 备注 | `app.py:1761` `update_note` | `PATCH /api/v1/items/{id}` | 阶段2 Task 16 | 待阶段4/5 |
| 续期 | `app.py:1739` `extend_item`、`keep_item:1749` | `PATCH /api/v1/items/{id}`（expires_at） | 阶段2 Task 16 | 待阶段4/5 |
| 复制 | Web JS 剪贴板 / Mac 桥 `copyText`（CopySync.m:1488）/ Android 桥 `copyText`（MainActivity:410） | v1 content + 桥 `clipboard.write` | 阶段3 | 待阶段4/5 |
| 下载 | `app.py:1784` `download`（签名 token 免登录 995） | `GET /api/v1/items/{id}/content?variant=` | 阶段2 Task 15 | 待阶段4/5 |
| 删除 | `app.py:1772` `delete_item` | `DELETE /api/v1/items/{id}`（墓碑） | 阶段2 Task 16 | 待阶段4/5 |
| 清理临时内容 | `app.py:1778` `clear_temp` + `cleanup:1161` | 保留路由 + v1 封装 | 待阶段2补 | 待阶段4/5 |
| 彻底清空 | `app.py:1781` `clear_all` | 保留路由 + v1 封装（二次确认） | 待阶段2补 | 待阶段4/5 |
| 容量 | `app.py:1241` `usage` + `GET /api/usage` | `GET /api/v1/usage` | 阶段2 Task 18 | 待阶段4/5 |
| 过期规则 | TTL 配置 `app.py:57-60`、`expires_at` 列 | 不变，迁移保留 | 阶段2 Task 7 | 待阶段4/5 |
| 刷新 | 各端刷新按钮 → `/api/items` 等 | `/api/v1/sync` 游标补齐 | 阶段2 Task 11 | 待阶段4/5 |
| 实时变化和更新提示 | SSE `app.py:1571`（ITEMS_VERSION） | `GET /api/v1/events` 版本通知 | 阶段2 Task 12 | 待阶段4/5 |

## Mac

| 能力 | 旧入口 | V3 去向 | 自动测试 | GUI 结果 |
|---|---|---|---|---|
| 菜单栏 | `CopySync.m:144-175` | macOS 桥 `menubar.*` | 阶段3 | 待阶段4/5 |
| 主窗口快捷键 ⌘. | `CopySync.m:1054-1069`（Carbon） | 桥 `hotkey.register(main)` | 阶段3 | 待阶段4/5 |
| 历史浮窗快捷键 ⌘,/⌥V/⇧⌘V | `CopySync.m:1071-1074` | 桥 `hotkey.register(history)` | 阶段3 | 待阶段4/5 |
| 区域截图 ⌘J | `CopySync.m:863`（screencapture -i） | 桥 `screenshot.captureRegion` | 阶段3 | 待阶段4/5 |
| 文本/图片本地历史 | `CopySync.m:342-386`（NSUserDefaults + 历史截图目录） | 桥 `history.*`（保留存储与上限 10 条语义） | 阶段3 | 待阶段4/5 |
| 去重 | `CopySync.m:337`（SHA-256 指纹置顶） | 桥 `history.*` 同语义 | 阶段3 | 待阶段4/5 |
| 历史悬浮固定 | `CopySync.m:609-674` | 桥 `history.pin` | 阶段3 | 待阶段4/5 |
| 复制并粘贴到前一应用 | `CopySync.m:824/1533/1553` | 桥 `paste.intoPreviousApp` | 阶段3 | 待阶段4/5 |
| 忽略下一次复制 | `CopySync.m:1109`（ignoreNextCopy） | 桥 `clipboard.write(ignoreNext)` | 阶段3 | 待阶段4/5 |
| 登录启动 | `CopySync.m:1090/1094`（SMAppService） | 桥 `loginItem.set` | 阶段3 | 待阶段4/5 |
| 状态栏开关 | `CopySync.m:1113`（显示底部状态栏） | 设置页 + 桥 | 阶段3 | 待阶段4/5 |
| 屏幕录制/粘贴权限入口 | `CopySync.m:900/919-922` | 桥 `permissions.status/request` | 阶段3 | 待阶段4/5 |
| 接收保存与 Finder 定位 | `CopySync.m:1215-1265` | 桥 `files.revealReceived` | 阶段3 | 待阶段4/5 |
| 缓存目录 | `CopySync.m:304-315`（~/Documents/CopySync 临时文件） | 不变 | 阶段3 | 待阶段4/5 |
| 清理历史/缓存 | `CopySync.m:571/588` | 桥 `cache.clear` + `history.clear` | 阶段3 | 待阶段4/5 |
| 检查/下载/覆盖安装更新 | `CopySync.m:931-1048`（SHA-256 校验 968） | 桥 `update.check/download/install` | 阶段3/5 | 待阶段5 |

## Android

| 能力 | 旧入口 | V3 去向 | 自动测试 | GUI 结果 |
|---|---|---|---|---|
| 底部导航 | `MainActivity.java:215` | Flutter 底部导航（四页固定） | 阶段3 | 待阶段4/5 |
| 下拉刷新 | `MainActivity.java:150-179/267` | Flutter RefreshIndicator → sync | 阶段3 | 待阶段4/5 |
| 系统分享入口 | `MainActivity.java:754`（ACTION_SEND） | 桥 `share.pending` | 阶段3 | 待阶段4/5 |
| 分享前确认 | `MainActivity.java:758-817` | 桥 `share.confirm`（确认对话框语义保留） | 阶段3 | 待阶段4/5 |
| 文件/照片选择 | `MainActivity.java:139/878` | 桥 `picker.files/photos` | 阶段3 | 待阶段4/5 |
| 接收通知 | `MainActivity.java:358`（channel copysync_delivery） | 桥 `notify.*` | 阶段3 | 待阶段4/5 |
| 下载状态恢复 | `MainActivity.java:629-700`（SharedPreferences 对账） | 桥 `download.enqueue/reconcile` | 阶段3 | 待阶段4/5 |
| 重复文件名处理 | `MainActivity.java:575/581` | 桥内同语义 | 阶段3 | 待阶段4/5 |
| 打开已接收文件 | `MainActivity.java:528-582` | 桥 `files.openReceived` | 阶段3 | 待阶段4/5 |
| 发送内容转存 | `MainActivity.java:396`（sent: 前缀） | 桥 `files.saveSent` | 阶段3 | 待阶段4/5 |
| 检查/下载/安装 APK 更新 | `MainActivity.java:899-981`（SHA-256 校验 957） | 桥 `update.check/download/install` | 阶段3/5 | 待阶段5 |

## 网页

| 能力 | 旧入口 | V3 去向 | 自动测试 | GUI 结果 |
|---|---|---|---|---|
| 线路探测与手动选择 | `app.py:1297` `/go` + `/probe:1619` | 保留路由 + 静态页 | 阶段4 | 待阶段4/5 |
| 登录 | 内嵌 JS → `/api/login` | `/api/v1/auth/login`（Cookie） | 阶段2 Task 10 | 待阶段4/5 |
| 拖拽上传 | 内嵌 JS → `/api/upload` | `POST /api/v1/items` | 阶段2/4 | 待阶段4/5 |
| 粘贴文本 | 内嵌 JS → `/api/text` | `POST /api/v1/items` | 阶段2/4 | 待阶段4/5 |
| 目标设备 | 内嵌 JS 设备选择 | `/api/v1/devices` + deliveries | 阶段2/4 | 待阶段4/5 |
| 全部列表操作 | 内嵌 JS → pin/note/extend/link/delete | `/api/v1/items` 系列 | 阶段2/4 | 待阶段4/5 |
| 搜索筛选 | 内嵌 JS | 静态 JS 同语义 | 阶段4 | 待阶段4/5 |
| 容量 | 内嵌 JS → `/api/usage` | `/api/v1/usage` | 阶段2 Task 18 | 待阶段4/5 |
| 在线设备数 | 内嵌 JS → `/api/devices` | `/api/v1/devices` | 阶段2 Task 9 | 待阶段4/5 |
| 刷新和实时变化通知 | EventSource `/api/events` | `/api/v1/events` + sync | 阶段2 Task 11/12 | 待阶段4/5 |
| 传输记录点击（文本→复制；文件→重新接收/定位） | **线上**内嵌 JS `openTransferRecord`（AnyCopy 版 app.py；copysync 2 树缺失） | 传输历史页行点击 | 阶段4 | 待阶段4/5 |
| 网盘列表项点击（文件下载定位/图片相册打开/文本复制） | **线上**内嵌 JS（AnyCopy 版；copysync 2 树缺失） | 列表行点击 | 阶段4 | 待阶段4/5 |

## Android（补充：线上 APK 有而 copysync 2 源码树缺失的行）

| 能力 | 旧入口 | V3 去向 | 自动测试 | GUI 结果 |
|---|---|---|---|---|
| 传输记录/网盘点击定位与打开 | 线上 APK 1.24/25：`viewReceivedFile`/`openDriveFile`（旧工程 1075 行 MainActivity）；copysync 2 树（988 行）缺失 | 桥 `files.openReceived` 扩展 | 阶段3 | 待阶段4/5 |

## 基线与线上版本事实（2026-08-24 核实）

- 线上 Mac 清单：2.0/build 34（sha256 `957cf193…734478`）；copysync 2 仓库代码为 2.2/build 35（含 WebView 恢复修复，**尚未发布**）。
- 线上 Android 清单：1.24/versionCode 25（sha256 `23690875…04d890`），与旧工程 `~/Documents/New project/copy-example` 的 APK 完全一致；copysync 2 的 `updates/android.json`（1.21/22，sha 不符）已过时。
- copysync 2 的 Android 源码树不完整：缺 `SyncService.java`、`AndroidManifest.xml`、`settings.gradle.kts`、wrapper 与 `viewReceivedFile/openDriveFile` 等 87 行差异；完整源在旧工程。
- 结论：功能基线 = 线上生产构建（旧工程）∪ copysync 2 新增修复；Android 完整源码与基线 APK 以旧工程为准，阶段 3c 前需移植进 copysync 2。

- 2026-08-24（kimi）：`python3 -m unittest test_app.py -v`，Python 3.14.4 → `Ran 22 tests in 0.057s / OK`。
- 2026-08-24（kimi）Android Emulator 基线（avd pskora_api35，API 35，线上 APK 1.24/25，sha256 23690875…04d890）：截图证据在 `assets/baseline/android/`（含敏感节点信息，已通过 `.git/info/exclude` 排除，不入库）。已操作验证：启动→通知权限弹窗（01/02）→登录（02-06，含密码表单与失败反馈 unauthorized）→收件箱列表与上传/复制按钮（07）→下拉刷新（08）→网盘容量/搜索/类型筛选/续期/复制/下载/删除/图钉（09）→设置对话框（后台同步三模式/接收文件夹/打开网页/退出后台同步/保存）（10）→传输记录点击→"文本已复制" toast（12）→系统分享面板含 AnyCopy（13）→分享确认对话框（目标设备/同步网页/取消/发送）（15）→发送成功且 curl 复核 `/api/transfers` 出现新 delivered 记录（16/17）→心跳生效"2 台设备在线"（17）。未覆盖：文件/照片选择器、下载状态恢复、打开已接收文件、APK 更新安装——阶段 5 正式 GUI 门补验。
- 网页/Mac GUI 基线（Task 3/4）：均已完成。
- 2026-08-25（kimi）Mac 基线（/Applications 生产实例 2.0/34，screencapture+cliclick+Swift CGEvent 真实操作，证据 `assets/baseline/mac/`）：主窗口+侧栏+文件列表（02）→菜单栏菜单全项：本地历史 10/10、截图/缓存用量、打开历史(⌘,)/跨设备传输(⌘.)、打开临时/接收文件夹、清空历史…、清理缓存…、区域截图(⌘J)、屏幕录制权限…、检查更新…、忽略下一次复制、底部状态栏✓、偏好设置…、登录时启动✓、请求粘贴权限、退出（03）→偏好设置弹窗（默认发送目标/同步网页/历史快捷键三选项/**屏幕录制已允许/直接粘贴已允许**/接收文件夹/状态栏）（06）→历史浮窗"最近复制"逐行 上传/发送/复制（05）→检查更新→状态栏"已经是最新版"（07）→清空历史…二次确认框点取消后历史仍为 10 条（08）。另实证：网页基线发的文本经 SSE 触达 Mac 弹通知。未完整走通：区域截图交互框选、粘贴到前一应用——入口存在+权限已允许，完整路径阶段 5 正式 GUI 门补验。
- 2026-08-25（kimi）Flutter 环境：Flutter 3.47.0、Android SDK 36/build-tools ✓、CocoaPods 1.17、Xcode 26.6（已 switch+runFirstLaunch）；`flutter_copysync` 工程已创建；macOS debug 构建 ✅。网络：pub.dev 不通→`PUB_HOSTED_URL=https://pub.flutter-io.cn`；maven central/google 直连不通→`~/.gradle/init.d/aliyun-mirror.gradle`（settings 级镜像）+ 项目 `android/build.gradle.kts` 镜像仓库。
- 2026-08-24（kimi）网页基线（本地实例 127.0.0.1:15080，kimi-webbridge 真实浏览器 Chrome 操作，证据 `assets/baseline/web/` 13 张）：登录页（01）→登录后主界面双栏（容量条/在线设备数/设备传输区）（02）→上传按钮上传文件 200（03）→粘贴文本发送→按钮"发送中…"加载态→deliveries waiting（04）→图钉（pinned=1、永久，续期按钮消失，符合预期）（05）→续期 expires_at +7 天（06）→复制 toast（07）→搜索"baseline"（08）→图片类型筛选（09）→/go 线路选择页（10）→删除（原生 confirm() 二次确认，app.py:813）（12）→清理临时内容（confirm，图钉项保留）（13）。说明：webbridge 上传工具对隐藏 file input 被拒，上传/拖拽改用以页面真实 input change/drop 事件驱动（同一 JS 处理函数）；confirm() 弹窗用预置 window.confirm 桩解除（webbridge 无法应答原生对话框）。发现：桌面网页列表行无"备注"按钮（API `/api/items/{id}/note` 存在但无入口），Android 收件箱每项有"上传/复制"——矩阵已含备注行，V3 需补桌面入口。
- 2026-08-24（kimi）迁移演练（Task 19，commit 9478bb4）：线上 SQLite 在线备份（Python backup API，VPS 无 sqlite3 CLI）→本机副本迁移两遍幂等、items(50,800)/devices(3)/deliveries(48) 不变、四新表建成、旧代码回滚可读、71 测试全绿。发现：生产 50 项中 16 项已过期未被清理（线上 cleanup 依赖请求触发，阶段 5 前确认 cron）。
