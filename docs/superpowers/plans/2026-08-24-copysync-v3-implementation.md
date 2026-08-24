# CopySync V3 实施计划：冻结基线 + API 与数据（阶段 1–2，含阶段 3–6 门控骨架）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按已批准设计 `docs/superpowers/specs/2026-08-24-copysync-v3-flutter-api-ui-rebuild-design.md`（下称"主设计"）实施 CopySync V3，本计划完整覆盖阶段 1（冻结基线）与阶段 2（API 与数据），并为阶段 3–6 锁定任务边界、接口与发布门。

**Architecture:** 在现有单文件 stdlib 服务端 `app.py` 上做增量迁移与 `/api/v1` 路由扩展（不引入框架、不建平行后端）；Web 客户端后续拆为静态 HTML/CSS/JS；Flutter 单工程产出 Mac+Android，经 Platform Channel 桥接现有 Objective-C/Java 能力。SSE 只通知版本号，真实状态走游标同步。

**Tech Stack:** Python 3 标准库（http.server + sqlite3，无第三方依赖）、unittest、Flutter/Dart、Objective-C（macOS 桥）、Java/Kotlin（Android 桥）、轻量 HTML/CSS/JS（网页）。

## Global Constraints

以下逐字或逐义来自主设计，全部任务默认继承：

- 现有全部用户功能必须存在、真实可用且不降级；不得删除、隐藏、占位或仅弹提示。
- 所有按钮必须连接真实 API 或原生能力，具有进行中、成功和失败反馈；请求中防止重复触发。
- Mac 与桌面网页必须严格按照主设计参考图实现；Android 除"底部导航 + 单列内容"外与 Mac 一致。
- 网页和 Mac 必须在真实 GUI 中逐按钮模拟手动操作；APK 必须在 Mac 上的 Android Emulator 模拟触摸逐项操作。自动测试不能替代该门槛。
- Android Emulator 不能证明厂商后台限制和真实剪贴板行为；发布前必须再做一台真实 Android 的最小冒烟测试。
- 不清空或覆盖现有 SQLite、文件、图钉、有效期、传输历史、用户配置及原生权限身份。
- 设备身份只能从 Token 得出，不接受请求体伪造 `source_device`；目标设备必须存在且未撤销。
- 原生 Token 存入系统安全存储；网页使用 `Secure + HttpOnly + SameSite` Cookie；数据库只保存 Token 哈希；Token 不进 URL、HTML、JS 可读存储或日志。
- 所有写请求支持客户端生成的幂等键；同设备同键重试必须返回第一次结果。
- 上传先写 `.part`，验证大小、MIME、SHA-256 和容量后原子提交；失败清理半成品；DB 与文件提交必须有补偿清理。
- 图片每个项目保留 `original` 与 `clipboard` 两个变体；GIF 原件保留动画，clipboard 变体用首帧 PNG；转换在 Mac ImageIO / Android 原生解码完成，服务端只校验和保存。
- 图片复制后只进本地历史，手动发送或上传；禁止默认自动上传。
- 错误响应至少含稳定 `code`、可显示 `message`、可选 `details`；HTTP 状态与错误性质一致。
- 游标不存在、损坏或早于保留窗口时返回 `full_sync_required`；本版不做客户端离线缓存和离线写队列。
- 明确不做：Flutter Web、复制图片自动上传、旧业务 API 发布后兼容、多用户/注册/对象存储/分片上传、第二套后端/设备模型/传输管线。
- 不引入第二套服务、消息队列、前端框架、仓库层、服务定位器、代码生成体系或多套状态框架。
- 所有敏感值禁止写入日志、设计文档、截图和交接文件。
- 危险操作必须明确目标和影响，且支持取消；删除、彻底清空和撤销设备必须二次确认。
- 迁移前备份线上 SQLite 与文件索引并记录校验值与恢复命令；迁移可重复执行，DB 部分在事务内完成。
- 每阶段完成后必须更新 `.ai/HANDOFF.md`（记录真实验证命令与结果），并用 `copysync-v3-completion-gate` 评估；任一门无证据即"未完成"。不得跨过失败阶段继续堆叠实现。
- 服务端保持纯标准库；新代码沿用 `app.py` 现有模式（`db()`、`send_json`、`fail`、`parse_form`、`AbortRequest`）。
- 已勘察事实：`android-copy/CopyWeb/` 源码树不完整（缺 `SyncService.java`、`AndroidManifest.xml`、`settings.gradle`、wrapper），不能独立编译；Android 基线与桥接工作依赖先找回完整工程或线上 APK（见 Task 5）。

## 阶段总览与阶段门

| 阶段 | 本计划覆盖度 | 出口门 |
|---|---|---|
| 1 冻结基线 | 完整任务（Task 1–5） | 基线矩阵 + 三端截图/手动结果入库，HANDOFF 更新 |
| 2 API 与数据 | 完整 TDD 任务（Task 6–20） | 全部新旧 unittest 通过 + 迁移在生产副本上验证 + 门禁评估 PASS |
| 3 Flutter 纵向闭环 | 任务边界与接口锁定（Task 21–24），进入阶段时用 test-driven-development + flutter-expert 展开为代码级步骤 | 登录/设备/文本/文件/图片双端闭环 + 桥接测试 |
| 4 功能与 UI | 任务边界锁定（Task 25–27），进入阶段时展开 | 零回退矩阵逐项勾验 + 三端视觉对照 |
| 5 发布候选 | 门控清单锁定（Task 28） | 自动门 + GUI 门 + 真机 + 覆盖升级 + 签名 + 回滚全部有证据 |
| 6 一次公开发布 | 发布窗口步骤锁定（Task 29） | Zane go/no-go → 原子切换 → 线上复测 |

阶段 3–6 不写死代码级步骤不是占位符，而是主设计 §13"不得跨过失败阶段继续堆叠实现"的直接要求：每个阶段入口先把该阶段任务展开为 TDD 步骤并记入 HANDOFF，再动手。

---

## 阶段 1：冻结基线

### Task 1: 基线功能矩阵文档

**Files:**
- Create: `docs/superpowers/specs/2026-08-24-copysync-v3-baseline-matrix.md`
- Reference: 主设计 §9；`app.py`；`mac-clipboard/CopySync.m`；`android-copy/CopyWeb/app/src/main/java/xyz/copyweb/MainActivity.java`

**Interfaces:**
- Produces: 矩阵文件，每行格式 `能力 | 平台 | 旧入口（文件:行号/路由） | V3 去向（页面/桥接/API） | 自动测试 | GUI 结果`，供阶段 4 逐项勾验。

- [ ] **Step 1: 写矩阵骨架**

按主设计 §9 四张清单逐行展开（通用 24 项、Mac 18 项、Android 11 项、网页 10 项），每行填"旧入口"。已勘察的关键锚点（写文档时逐条核对原文）：

- 服务端路由：`app.py` do_GET 1291-1344 / do_POST 1367-1426 / do_DELETE 1427；登录 1450、改密码 1478、items 1514、devices 1524、transfers 1536、usage 1326、SSE 1571、下载 1784、图钉 1727、续期 1739、keep 1749、备注 1761、删除 1772、清理 1778/1781、定向发送 1695、ack 1706、心跳 1720。
- Mac：菜单栏 `CopySync.m:144-175`、快捷键 1054-1074、剪贴板监听 1420、区域截图 863、历史+去重 337-386、悬浮固定 609-674、粘贴到前一应用 824/1533/1553、忽略下一次复制 1109、登录启动 1090、权限入口 900/919、接收保存与 Finder 定位 1215-1265、缓存目录 304-315、更新 931-1048。
- Android：底栏 `MainActivity.java:215`、下拉刷新 150-179/267、分享入口与确认 754-817、文件照片选择 139/878、通知 358、下载与恢复 440-700、重名处理 575/581、打开已接收 528、发送转存 396、APK 更新 899-981。
- 网页：内嵌 `INDEX_HTML`（`app.py:87-870`），线路选择 `/go`、登录、拖拽上传、粘贴文本、目标设备、列表操作、搜索筛选、容量、在线设备数、刷新、SSE。

"V3 去向"列按主设计 §5–§8 填写（如"心跳 → `POST /api/v1/devices/{id}/heartbeat`"；"菜单栏 → macOS 桥 `menubar.*`"）。"自动测试"与"GUI 结果"列在阶段 1 填 `待阶段2/4`，阶段 4 逐行回填真实结果。

- [ ] **Step 2: 核对并提交**

Run: `cd "/path/to/copysync" && python3 -c "print(open('docs/superpowers/specs/2026-08-24-copysync-v3-baseline-matrix.md').read().count('|'))"` 人工抽查 10 行锚点与源码一致。
Run: `git add docs/superpowers/specs/2026-08-24-copysync-v3-baseline-matrix.md && git commit -m "docs: freeze v3 baseline feature matrix"`

### Task 2: 服务端自动基线

**Files:**
- Modify: `docs/superpowers/specs/2026-08-24-copysync-v3-baseline-matrix.md`（追加"基线验证记录"节）

- [ ] **Step 1: 跑现有测试并记录**

Run: `cd "/path/to/copysync" && python3 -m unittest test_app.py -v 2>&1 | tail -5`
Expected: `Ran 22 tests` / `OK`。把命令、结果、Python 版本（`python3 -V`）写入基线文档。

- [ ] **Step 2: 提交**

Run: `git add -A docs && git commit -m "docs: record server baseline test result"`

### Task 3: 网页端基线（真实浏览器 GUI）

**Files:**
- Create: `docs/superpowers/specs/assets/baseline/web/*.png`
- Modify: 基线矩阵"GUI 结果"列（网页行）

- [ ] **Step 1: 起本地服务**

Run: `cd "/path/to/copysync" && WEBCLIP_DATA_DIR=/tmp/copysync-baseline python3 app.py &`，确认 `curl -s http://127.0.0.1:15080/healthz` 返回 `ok`。用完后 `kill %1`。

- [ ] **Step 2: 用 kimi-webbridge 逐项操作并截图**

在真实浏览器打开 `http://127.0.0.1:15080/`（基线用本地实例，避免碰线上）：登录、线路选择页、拖拽上传一个文件、粘贴文本、定向发送到设备、列表每项操作（复制/下载/图钉/备注/续期/删除）、搜索筛选、容量显示、刷新。每个动作截图存 `assets/baseline/web/`，在矩阵记录"输入/预期/实际"。

- [ ] **Step 3: 提交**

Run: `git add docs && git commit -m "docs: freeze web baseline gui evidence"`

### Task 4: Mac 端基线（真实 GUI）

**Files:**
- Create: `docs/superpowers/specs/assets/baseline/mac/*.png`
- Modify: 基线矩阵"GUI 结果"列（Mac 行）

- [ ] **Step 1: 验证现有构建可用**

Run: `cd "/path/to/copysync" && zsh mac-clipboard/test-recovery.sh && ls -la mac-clipboard/build-2.0/CopySync.app`
Expected: 冒烟脚本通过、.app 存在且已签名（`codesign -dv mac-clipboard/build-2.0/CopySync.app 2>&1 | head -5`）。

- [ ] **Step 2: 安装并逐项操作**

`open mac-clipboard/build-2.0/CopySync.app`（连接本地基线实例需在系统层临时改基址或直接对线上只读操作——选择对线上 `https://copy-direct.example.com` 做只读项 + 对本地实例做写项，写入 HANDOFF）。用 osascript/System Events + `screencapture` 逐项：窗口与侧栏、菜单栏每一项、⌘. / ⌘, / ⌘J 快捷键、文本/图片历史与去重、区域截图、悬浮固定、复制并粘贴到前一应用、忽略下一次复制、权限入口、接收与 Finder 定位、清理、检查更新。截图存 `assets/baseline/mac/` 并回填矩阵。

- [ ] **Step 3: 提交**

Run: `git add docs && git commit -m "docs: freeze mac baseline gui evidence"`

### Task 5: Android 端基线（含工程完整性阻塞处理）

**Files:**
- Create: `docs/superpowers/specs/assets/baseline/android/*.png`（若可安装）
- Modify: `.ai/HANDOFF.md`、基线矩阵

**背景（已勘察事实）：** `android-copy/CopyWeb/` 缺 `SyncService.java`（`MainActivity.java:342/382/385` 引用）、`AndroidManifest.xml`、`settings.gradle`、wrapper，当前树无法编译 APK；`updates/` 本地也没有 APK 文件。

- [ ] **Step 1: 尝试取得可安装基线 APK**

顺序尝试：(a) `curl -s https://copy-direct.example.com/updates/CopyWeb-Android-latest.apk -o /tmp/CopyWeb-baseline.apk` 并用 `shasum -a256` 对 `updates/android.json` 的 sha256 校验；(b) 在本机 `mdfind -name "CopyWeb*.apk"`、常见构建输出目录找历史 APK；(c) 找完整 Android 工程副本。任一路径成功即记录来源与校验值。

- [ ] **Step 2: Emulator 安装并逐项操作**

`adb devices` 确认模拟器在线（无则用 `emulator -avd <已存在AVD>` 启动，都没有则建一个 API 35 avd）。`adb install /tmp/CopyWeb-baseline.apk`，用 `adb shell input tap/swipe/text` + `adb exec-out screencap` 逐项：底栏、下拉刷新、分享确认、文件/照片选择、发送、接收、下载、通知、后台恢复、设置、APK 更新检查。截图存 `assets/baseline/android/` 并回填矩阵。

- [ ] **Step 3: 若 Step 1 全部失败——停止并上报**

不得跳过 Android 基线进入阶段 3 的 Android 侧工作。把阻塞写入 HANDOFF（状态"已阻塞"，下一步唯一动作 = 需要 Zane 提供完整 Android 工程或基线 APK），继续阶段 2（服务端不依赖 Android）。

- [ ] **Step 4: 提交**

Run: `git add docs && git commit -m "docs: freeze android baseline gui evidence"`

---

## 阶段 2：API 与数据

所有新代码在 `app.py` 内，沿用现有模式。新测试进 `test_app.py`（unittest，沿用其临时目录隔离写法）。每个 Task 的 Step 顺序固定为：写失败测试 → 跑确认失败 → 最小实现 → 跑确认通过 → 提交。下方给出关键测试与实现代码；跑测试统一用 `cd "/path/to/copysync" && python3 -m unittest test_app.py -v`。

### Task 6: v1 错误格式与 v1 测试基座

**Files:**
- Modify: `app.py`（新增 `api_fail`、v1 路由分发钩子）
- Test: `test_app.py`

**Interfaces:**
- Produces: `Handler.api_fail(status, code, message, details=None)` → `{"error":{"code","message","details"}}`；`Handler.v1_device()` → 解析 `Authorization: Bearer` 或网页 Cookie 返回设备行或 None；测试基座 `V1Case(unittest.TestCase)` 含 `self.login_device(name, platform)` helper。

- [ ] **Step 1: 写失败测试**

```python
def test_v1_error_shape(self):
    status, body = self.raw_get("/api/v1/devices")  # 未认证
    self.assertEqual(status, 401)
    self.assertEqual(body["error"]["code"], "unauthorized")
    self.assertIn("message", body["error"])
```

- [ ] **Step 2: 跑确认失败** — Expected: 404/非 JSON，`KeyError`/`AssertionError`。

- [ ] **Step 3: 最小实现**

在 `Handler` 加：

```python
def api_fail(self, status, code, message, details=None):
    err = {"code": code, "message": message}
    if details is not None:
        err["details"] = details
    self.send_json({"error": err}, status=status)  # send_json 需支持 status 参数，见下
```

`send_json` 改为 `def send_json(self, data, headers=None, status=200): ... self.send(status, ...)`（现有调用全部不传 status，兼容）。`do_GET/do_POST/do_DELETE/do_PATCH` 入口最前面加：`if self.path.startswith("/api/v1/"): return self.route_v1()`；`route_v1` 用 `urllib.parse.urlsplit(self.path)` 拆 path/query，按前缀表分发，未匹配走 `api_fail(404, "not_found", "接口不存在")`。新增 `do_PATCH`（现有类没有 PATCH）。

- [ ] **Step 4: 跑确认通过** — Expected: 该测试 PASS，原 22 测试不回归。

- [ ] **Step 5: 提交** — `git add app.py test_app.py && git commit -m "feat(api): v1 error envelope and route dispatch"`

### Task 7: 增量 Schema 迁移（四张新表）

**Files:**
- Modify: `app.py` `init()`（885-972 之后追加 `migrate_v1(conn)`，由 `init()` 在同事务调用）
- Test: `test_app.py`

**Interfaces:**
- Produces: `migrate_v1(conn)`；表 `device_tokens(id INTEGER PK, device_id TEXT, token_hash TEXT UNIQUE, created_at TEXT, last_used_at TEXT, revoked_at TEXT)`、`item_blobs(id INTEGER PK, item_id INTEGER, variant TEXT, stored_name TEXT, mime TEXT, size INTEGER, sha256 TEXT, created_at TEXT, UNIQUE(item_id, variant, stored_name))`、`sync_changes(seq INTEGER PK AUTOINCREMENT, entity TEXT, entity_id TEXT, op TEXT, created_at TEXT)`、`idempotency_keys(device_id TEXT, idem_key TEXT, result_json TEXT, created_at TEXT, expires_at TEXT, PRIMARY KEY(device_id, idem_key))`。

- [ ] **Step 1: 写失败测试**

```python
def test_migrate_v1_creates_tables_and_is_repeatable(self):
    conn = app.db()
    app.migrate_v1(conn); app.migrate_v1(conn)  # 二次执行不抛错
    tables = {r[0] for r in conn.execute("select name from sqlite_master where type='table'")}
    for t in ("device_tokens", "item_blobs", "sync_changes", "idempotency_keys"):
        self.assertIn(t, tables)

def test_migrate_v1_backfills_item_blobs_original(self):
    # 预置一个带文件的 item 后迁移：item_blobs 出现 variant='original' 行且 sha256 与文件一致
```

- [ ] **Step 2: 跑确认失败** — Expected: `AttributeError: module 'app' has no attribute 'migrate_v1'`。

- [ ] **Step 3: 最小实现**

```python
def migrate_v1(conn):
    conn.executescript("""
    create table if not exists device_tokens(...);
    create table if not exists item_blobs(...);
    create table if not exists sync_changes(...);
    create table if not exists idempotency_keys(...);
    create index if not exists idx_sync_changes_seq on sync_changes(seq);
    """)
    rows = conn.execute(
        "select i.id, i.stored_name, i.mime, i.size from items i "
        "where i.stored_name != '' and not exists ("
        "  select 1 from item_blobs b where b.item_id = i.id and b.variant = 'original')").fetchall()
    for item_id, stored, mime, size in rows:
        path = os.path.join(FILES_DIR, stored)
        if not os.path.exists(path):
            continue
        conn.execute(
            "insert into item_blobs(item_id, variant, stored_name, mime, size, sha256, created_at) "
            "values (?,?,?,?,?,?,?)",
            (item_id, "original", stored, mime, size, sha256_file(path), now_iso()))
```

新增 `sha256_file(path)`（分块读）与 `now_iso()`。`init()` 在现有建表后、commit 前调用 `migrate_v1(conn)`（同事务）。

- [ ] **Step 4: 跑确认通过** — Expected: 两个测试 PASS，原测试不回归；对一个预置旧库（先 checkout 旧 init 建库再跑新 init）验证主键与数据保留。

- [ ] **Step 5: 提交** — `git commit -m "feat(api): incremental v1 schema migration with blob backfill"`

### Task 8: 设备 Token 签发与 `POST /api/v1/auth/login`

**Files:**
- Modify: `app.py`
- Test: `test_app.py`

**Interfaces:**
- Consumes: `migrate_v1`、`api_fail`、`password_ok`（`app.py:1019`）、`login_failures` 限流逻辑（1450-1470，抽出共用）。
- Produces: `issue_device_token(conn, device_id) -> raw_token`（`"cps_" + secrets.token_urlsafe(32)`，库存 `hashlib.sha256(raw.encode()).hexdigest()`）；`v1_device()`；路由 `POST /api/v1/auth/login`，请求 JSON `{"password","device_name","platform"}` → `{"token","device":{"id","name","platform"}}`。

- [ ] **Step 1: 写失败测试**

```python
def test_v1_login_issues_per_device_token(self):
    s1, b1 = self.raw_post("/api/v1/auth/login", {"password": PW, "device_name": "Mac", "platform": "mac"})
    s2, b2 = self.raw_post("/api/v1/auth/login", {"password": PW, "device_name": "Mac", "platform": "mac"})
    self.assertEqual(s1, 200); self.assertNotEqual(b1["token"], b2["token"])  # 每设备/每次独立
    conn = app.db()
    hashes = [r[0] for r in conn.execute("select token_hash from device_tokens")]
    self.assertNotIn(b1["token"], hashes)  # 只存哈希
def test_v1_login_wrong_password_401(self): ...  # code='invalid_credentials'
def test_v1_login_rate_limited(self): ...  # 8 次失败后 429/423，code='login_locked'
```

- [ ] **Step 2: 跑确认失败** — Expected: 404 `not_found`。

- [ ] **Step 3: 最小实现**

`route_v1` 加 `"POST /api/v1/auth/login" → self.v1_login()`。`v1_login`：复用限流检查 → `password_ok` → 在 `devices` 表按 name+platform 找或建设备行 → `issue_device_token` → `record_change(conn,"device",device_id,"upsert")`（Task 11 实现，本任务先内联 insert sync_changes，Task 11 统一抽函数）→ 返回 token。响应不含任何哈希；日志不记 token。

- [ ] **Step 4: 跑确认通过。**

- [ ] **Step 5: 提交** — `git commit -m "feat(api): per-device token login for /api/v1"`

### Task 9: Token 校验、logout、设备管理与心跳

**Files:**
- Modify: `app.py`
- Test: `test_app.py`

**Interfaces:**
- Produces: `v1_device()` 完整实现（Bearer 或 Cookie → sha256 查 `device_tokens` 未撤销 → join `devices` enabled=1 → 更新 `last_used_at`；失败 None）；路由 `POST /api/v1/auth/logout`（撤销当前 token）、`GET /api/v1/devices`、`PATCH /api/v1/devices/{id}`（改名）、`DELETE /api/v1/devices/{id}`（撤销设备+其全部 token）、`POST /api/v1/devices/{id}/heartbeat`（路径 id 必须等于 token 的 device_id，否则 403 `device_mismatch`）。

- [ ] **Step 1: 写失败测试**

```python
def test_v1_devices_requires_auth_and_lists(self): ...
def test_v1_logout_revokes_token(self):  # logout 后同 token 访问 401 code='token_revoked'
def test_v1_heartbeat_path_must_match_token(self):  # 用 A 的 token 打 /devices/B/heartbeat → 403
def test_v1_delete_device_revokes_all_tokens(self):  # 该设备所有 token 失效
def test_v1_rename_device(self): ...
```

- [ ] **Step 2–5:** 跑失败 → 实现（心跳同时更新 `devices.last_seen_at` 并 `record_change`）→ 跑通过 → `git commit -m "feat(api): v1 device auth, management and heartbeat"`。

### Task 10: 网页 Cookie 承载 v1 Token

**Files:**
- Modify: `app.py`
- Test: `test_app.py`

**Interfaces:**
- Produces: `POST /api/v1/auth/login` 当请求带 `X-Client: web`（或表单 `client=web`）时，除 JSON 响应外设置 `Set-Cookie: webclip_v1=<token>; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000`；`v1_device()` 在无 Bearer 时读该 Cookie；logout 清 Cookie。

- [ ] **Step 1: 写失败测试**

```python
def test_v1_web_login_sets_secure_httponly_cookie(self):
    status, headers, body = self.raw_post_full("/api/v1/auth/login", {"password": PW, "device_name": "web", "platform": "web", "client": "web"})
    cookie = headers["Set-Cookie"]
    for attr in ("Secure", "HttpOnly", "SameSite=Lax"):
        self.assertIn(attr, cookie)
def test_v1_cookie_auth_works_without_bearer(self): ...
```

- [ ] **Step 2–5:** 常规 TDD 循环 → `git commit -m "feat(api): web cookie transport for v1 tokens"`。

### Task 11: 变更序号与 `GET /api/v1/sync`

**Files:**
- Modify: `app.py`
- Test: `test_app.py`

**Interfaces:**
- Consumes: `sync_changes` 表、`notify_items_changed()`（`app.py:1209`，SSE 版本号保持不变）。
- Produces: `record_change(conn, entity, entity_id, op)`（op ∈ `upsert|delete`）；`GET /api/v1/sync?cursor=N` → `{"changes":[...],"tombstones":[...],"next_cursor":M}`；游标缺失/非整数/小于保留窗口最小值 → 409 `{"error":{"code":"full_sync_required",...}}`；`cursor=0` 返回全量。保留窗口：常量 `SYNC_KEEP = 10000` 行，每次插入后 `delete from sync_changes where seq < (select max(seq) from sync_changes) - 10000`。

- [ ] **Step 1: 写失败测试**

```python
def test_sync_full_from_zero_and_incremental(self):
    self.login_device("Mac", "mac")
    self.v1_post_text("hello")                    # 产生 seq1
    s, b = self.raw_get("/api/v1/sync?cursor=0", auth=True)
    full_count = len(b["changes"]); cursor = b["next_cursor"]
    self.v1_post_text("world")
    s, b = self.raw_get(f"/api/v1/sync?cursor={cursor}", auth=True)
    self.assertEqual(len(b["changes"]), 1)        # 只增量
def test_sync_bad_cursor_requires_full(self):
    for bad in ("abc", "-1"):
        s, b = self.raw_get(f"/api/v1/sync?cursor={bad}", auth=True)
        self.assertEqual((s, b["error"]["code"]), (409, "full_sync_required"))
def test_sync_tombstone_on_delete(self): ...      # 删除后 changes 含 op='delete' 且在 tombstones
```

- [ ] **Step 2–5:** 实现 `record_change` 并接入 Task 8/9 已写的写路径；实现 sync 路由 → `git commit -m "feat(api): cursor-based incremental sync with tombstones"`。

### Task 12: `GET /api/v1/events`（SSE 版本通知）

**Files:** Modify `app.py`；Test `test_app.py`

- [ ] **Step 1:** 失败测试：v1 events 返回 `text/event-stream` 且首包含版本号；不带旧 HTML。
- [ ] **Step 2–5:** 复用 `stream_events`（1571）的版本号机制，v1 路由要求 v1 认证；`git commit -m "feat(api): v1 sse version notifications"`。

### Task 13: 幂等键

**Files:** Modify `app.py`；Test `test_app.py`

**Interfaces:**
- Produces: `idem_replay(conn, device_id, key) -> dict|None`；`idem_store(conn, device_id, key, result)`；v1 全部写路由读 `Idempotency-Key` 头：命中且未过期（24h）→ 直接返回 `result_json`（HTTP 200 + `X-Idempotent-Replay: 1`）；未命中 → 执行并在同事务 `idem_store`。

- [ ] **Step 1: 写失败测试**

```python
def test_idempotent_create_returns_first_result(self):
    h = {"Idempotency-Key": "k-123"}
    s1, b1 = self.v1_post("/api/v1/items", {"kind": "text", "text": "hi"}, headers=h)
    s2, b2 = self.v1_post("/api/v1/items", {"kind": "text", "text": "hi"}, headers=h)
    self.assertEqual(b1["item"]["id"], b2["item"]["id"])
    conn = app.db()
    self.assertEqual(conn.execute("select count(*) from items where text='hi'").fetchone()[0], 1)
def test_idempotency_scoped_per_device(self): ...  # 另一设备同 key 不复用
```

- [ ] **Step 2–5:** 实现并接入 → `git commit -m "feat(api): idempotency keys for v1 writes"`。

### Task 14: `POST /api/v1/items`（文本 + 文件/图片，原件变体）

**Files:** Modify `app.py`；Test `test_app.py`

**Interfaces:**
- Consumes: `parse_form`（1142）、`.part` 原子写（1677-1680）、容量校验（1650-1664）、`create_delivery`（1248）、`record_change`、幂等。
- Produces: 路由按 Content-Type 分流：`application/json` `{"kind":"text","text","note?","ttl?","target_device?"}`；`multipart/form-data` 文件字段 + 可选 `clipboard_variant` 文件字段（图片时）。响应 `{"item":{...}}`。`source_device` 一律取 token 设备，请求体里的 `source_device` 字段被忽略。

- [ ] **Step 1: 写失败测试**

```python
def test_v1_post_text_item(self): ...
def test_v1_upload_file_records_original_blob(self):
    # 上传 png → item_blobs 有 variant='original'，sha256 匹配，磁盘无 .part 残留
def test_v1_source_device_cannot_be_forged(self):
    # token 属于 mac，body 里 source_device='web' → 结果 item.source_device == 'mac'
def test_v1_upload_respects_capacity(self): ...  # 超 MAX_FILE_BYTES → 413 code='file_too_large'
```

- [ ] **Step 2–5:** 实现（复用现有 `upload`/`add_text` 的校验与落盘，新增 `insert_item_v1` 统一入口写 items + item_blobs + sync_changes + 幂等，一处 DB 提交）→ `git commit -m "feat(api): v1 item creation with original blob variant"`。

### Task 15: 图片 clipboard 变体接收与 `content?variant=`

**Files:** Modify `app.py`；Test `test_app.py`

**Interfaces:**
- Produces: multipart 上传时 `clipboard_variant` 字段落 `item_blobs(variant='clipboard')`；`GET /api/v1/items/{id}/content?variant=original|clipboard`（默认 original；clipboard 不存在 → 404 `variant_missing`，message 含具体格式说明）；变体验证：MIME ∈ 图片白名单（png/jpeg/webp/gif/heic）、大小 ≤ `MAX_FILE_BYTES`、sha256 与声明一致（客户端可声明 `clipboard_sha256` 字段，声明则强校验）。

- [ ] **Step 1: 写失败测试**

```python
def test_clipboard_variant_stored_and_served(self): ...
def test_variant_missing_reports_clearly(self): ...  # 404 variant_missing
def test_variant_sha_mismatch_rejected(self): ...    # 400 code='sha256_mismatch'，且不产生幽灵 item
```

- [ ] **Step 2–5:** 实现（变体也走 `.part` + 原子改名 + 失败补偿清理）→ `git commit -m "feat(api): clipboard image variant pipeline"`。

### Task 16: items 元数据/PATCH/DELETE（图钉、备注、有效期、墓碑）

**Files:** Modify `app.py`；Test `test_app.py`

- [ ] **Step 1:** 失败测试：`GET /api/v1/items/{id}`；`PATCH` 改 pinned/note/expires_at 并在 sync 中出现 upsert；`DELETE` 后 content 404、sync tombstones 含该 id、文件被删；图钉超 `PINNED_LIMIT` → 409 `pinned_limit`。
- [ ] **Step 2–5:** 实现（复用 `toggle_pin`/`update_note`/`extend_item`/`delete_item` 逻辑，包成 v1 语义 + `record_change` + 幂等）→ `git commit -m "feat(api): v1 item metadata, patch, delete with tombstones"`。

### Task 17: 定向发送与收件确认

**Files:** Modify `app.py`；Test `test_app.py`

- [ ] **Step 1:** 失败测试：`POST /api/v1/items/{id}/deliveries` `{"target_device":"android"}` → 目标设备 sync 可见；目标不存在/已撤销 → 404/409 `device_unavailable`；`POST /api/v1/deliveries/{id}/ack` 只能由目标设备的 token 确认，状态流转保持现有 `waiting→delivered→downloaded` 语义（含 android delivered→waiting 降级语义迁移说明写入矩阵）；ack 进 sync_changes。
- [ ] **Step 2–5:** 实现（复用 `create_delivery` 1248、`ack_delivery` 1706）→ `git commit -m "feat(api): v1 targeted delivery and ack"`。

### Task 18: `GET /api/v1/usage`

- [ ] **Step 1:** 失败测试：返回临时/图钉/总量与上限，数值与 `usage()`（1241）一致。
- [ ] **Step 2–5:** 薄封装 → `git commit -m "feat(api): v1 usage"`。

### Task 19: 迁移演练（生产副本）

**Files:** Modify `.ai/HANDOFF.md`；Create `docs/superpowers/specs/2026-08-24-copysync-v3-migration-rehearsal.md`

- [ ] **Step 1:** 备份线上数据：`ssh <VPS> "systemctl stop copy-example && cp -a /opt/copy-example/data /opt/copy-example/data.bak-v3-$(date +%Y%m%d) && sha256sum data/clipboard.db"`，校验值与恢复命令写入演练文档（VPS 凭证从 `$HOME/Documents/yaml 文件/vps` 读取，不写入任何文档）。
- [ ] **Step 2:** 把生产 `clipboard.db` + `files/` 副本拉到本地临时目录，用新代码 `init()` 迁移：验证四张新表、item_blobs 回填数量=有文件 item 数、items 主键与字段不变、`python3 -m unittest` 对迁移后库通过。
- [ ] **Step 3:** 二次执行迁移确认幂等；用备份恢复确认回滚路径可用（本地副本上演练，不动线上）。
- [ ] **Step 4:** 记录全部命令与结果，提交演练文档：`git commit -m "docs: v1 migration rehearsal on production copy"`。

### Task 20: 阶段 2 门禁

- [ ] **Step 1:** `python3 -m unittest test_app.py -v` 全绿（原 22 + 新增），输出存 HANDOFF。
- [ ] **Step 2:** `copysync-v3-completion-gate` 按"内部阶段"口径评估：只声明阶段 2 完成，不声明 V3 可发布。
- [ ] **Step 3:** 更新 HANDOFF（验证命令+结果+下一步=阶段 3 展开），`git commit`。

---

## 阶段 3–6：门控骨架（进入阶段时按 writing-plans + test-driven-development 展开为代码级步骤）

### Task 21: Flutter 工程与共享层（阶段 3a）

**Files（进入阶段时创建）:** `flutter_copysync/`（`flutter create --platforms=macos,android`）、`lib/api/`（v1 模型/认证/同步）、`lib/state/`（认证/同步/项目/按钮操作状态，单一 ChangeNotifier 体系，不加额外框架）、`test/`。

**接口锁定（Dart 侧，阶段 3 所有任务依赖）:**
- `ApiClient.login(password, deviceName, platform) -> String token`；`sync(cursor) -> SyncPage{changes,tombstones,nextCursor}`；`createTextItem(text, {targetDevice, idemKey})`；`uploadFile(path, {clipboardVariantPath, targetDevice, idemKey})`；`patchItem / deleteItem / contentUrl(id, variant) / sendTo / ack / usage / devices / heartbeat`。
- 桥接统一接口 `NativeBridge`：每个方法返回 `BridgeResult{ok, value, errorCode, errorMessage}`，禁止静默失败：
  - macOS：`menubar.*`、`hotkey.register(main/history/screenshot)`、`clipboard.watch/start/stop`、`clipboard.readImage/readText/write(item,{ignoreNext})`、`screenshot.captureRegion`、`paste.intoPreviousApp(item)`、`history.*`（本地历史+去重+悬浮固定）、`permissions.status/request(screenRecording,postEvent)`、`loginItem.set(enabled)`、`notify.show`、`files.revealReceived/saveSent`、`cache.usage/clear`、`update.check/download/install`。
  - Android：`share.pending/confirm`、`picker.files/photos`、`notify.*`、`download.enqueue/reconcile`、`files.revealReceived/saveSent/openReceived`、`update.check/download/install`、`background.start/stop`（前台服务）。
- 验收：登录→设备→文本发送/接收纵向闭环在 macOS 真窗与 Android Emulator 各跑通一次（GUI 证据），随后文件/图片（含双变体）闭环；桥接测试覆盖成功/拒绝权限/取消选择/系统错误/恢复路径。

### Task 22: macOS 原生桥接（阶段 3b）

**Files:** `flutter_copysync/macos/Runner/` 桥接代码 + 迁移 `mac-clipboard/CopySync.m` 已验证能力（逐能力搬移，行号锚点见 Task 1 矩阵；WebView 相关恢复回调不搬，按主设计 §9 用 Flutter 原生错误/重试 UI 替代）。
**验收:** 矩阵 Mac 行逐条有对应桥接方法且 GUI 实测通过；签名沿用 `CopySync Local Signing` 证书策略保证 TCC 授权跨更新有效（build-dmg.sh L16-22 模式）。

### Task 23: Android 原生桥接（阶段 3c）

**前置阻塞:** Task 5 的完整工程/APK 问题必须已解决；缺失的 `SyncService.java`、`AndroidManifest.xml`、分享/下载/通知代码需从可运行基线反推重建（以基线 APK 行为为准），否则 Android 侧不得声称桥接完成。
**验收:** 矩阵 Android 行逐条对应桥接方法；Emulator 逐项操作通过。

### Task 24: Flutter 页面与状态（阶段 3d）

收件箱、传输历史、临时网盘、设置四页 + 设计 token（颜色/圆角/模糊/阴影按参考图）；列表行（类型图标/标题/来源状态/时间大小/主操作/更多菜单）；每操作 idle/loading/success/error + 防重；长文本省略但可访问完整值；44×44 点击区；键盘优先历史浮窗（输入即搜索/方向键/回车粘贴）。
**验收:** widget 测试（长文本、加载/空/错误、防重）+ golden 初稿。

### Task 25: 网页客户端拆分（阶段 4a）

**Files:** 新建 `web/`（index.html / app.css / app.js），`app.py` 静态托管并删除 `INDEX_HTML` 内嵌（`app.py:87-870`）；功能与视觉按主设计 §8.1 + 参考图；调 `/api/v1`（Cookie 认证）；保留 `/go` 线路选择。
**验收:** webapp-testing 自动证据 + kimi-webbridge 真实浏览器逐项 GUI 证据（主设计 §11.2 清单全覆盖）。

### Task 26: 三端视觉与布局对齐（阶段 4b）

Mac/网页按参考图尺寸截图叠加对照（结构/间距/颜色/层级）；Android 标准手机尺寸 + 系统字体放大截图；默认/加载/空/长文本/多按钮/错误/离线/权限拒绝全状态；自动布局断言可点击元素在可视区内且边界不相交。

### Task 27: 零回退矩阵逐项勾验（阶段 4c）

Task 1 矩阵每行回填"自动测试 + GUI 结果"；任一缺失即 FAIL，回到对应任务修复，不得进入阶段 5。

### Task 28: 发布候选（阶段 5）

按主设计 §11 全部门：`python3 -m unittest` 全绿；Flutter 测试全绿；桥接测试全绿；新装/覆盖安装/签名/版本/更新清单/SHA-256/数据保留/回滚检查；网页+Mac 真实 GUI 逐项（kimi-webbridge / osascript+screencapture 留证）；APK Emulator 逐项（adb 留证）；**一台真实 Android 最小冒烟**（启动/登录/发送/后台收件/图片复制粘贴/分享入口/更新）——此项需要 Zane 的真机配合，提前约时间。全部证据入库后 `copysync-v3-completion-gate` 按"发布候选"口径评估。

### Task 29: 一次公开发布窗口（阶段 6）

严格按主设计 §12.2 顺序：生成并验证四端包 → 全部门通过 → **Zane 最终 go/no-go** → 备份线上数据 → 原子部署 `/api/v1`+新网页+迁移 → 发布 Mac/APK 更新清单（旧 CRUD 路由转 `426 Upgrade Required`，更新清单路由保留）→ 线上复测登录/发送/收件/图片粘贴/下载/更新链路。任一环节失败按 §12.3 立即停止并回滚（已验证备份+旧服务包+旧网页+旧更新清单）。完成后 `copysync-v3-completion-gate` 按"推送后/最终"口径评估，更新 HANDOFF 为已完成。

---

## 风险登记（随阶段推进更新）

1. **Android 工程不完整**（最高优先级）：缺 `SyncService.java`/`AndroidManifest.xml`/Gradle 骨架，阶段 1 Task 5 与阶段 3c 都依赖解决；解决前 Android 侧一切完成声明无效。
2. `updates/android.json`（versionCode 22）落后于 build.gradle（24），发布前需对齐版本策略。
3. multipart 目前整体读入内存（`app.py:1142-1159` + `read_body`），110MB 上限下可接受，V3 不改为流式（属"明确不做"的分片上传范畴），但测试需覆盖上限边界。
4. Flutter/macOS 工程需要本机 Flutter SDK；进入阶段 3 前先 `flutter --version` 验证环境，缺失则先装（不污染系统目录）。
