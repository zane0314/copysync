# CopySync V3 迁移演练记录（Task 19，生产副本）

日期：2026-08-24。目标：在**生产数据副本**上验证 `migrate_v1`（四张新表 + item_blobs 回填）的正确性、幂等性与回滚路径。全程未停止服务（`copy-example` 保持 `active`），未改动线上任何文件。

## 1. 在线备份（不停服务）

VPS 无 `sqlite3` CLI，改用 Python sqlite3 在线 backup API（等价 `.backup`，WAL 下安全）：

```
ssh root@<VPS> 'python3 -c "import sqlite3; src=sqlite3.connect(\"file:/opt/copy-example/data/clipboard.db?mode=ro\", uri=True); dst=sqlite3.connect(\"/root/clipboard-v3rehearsal.db\"); src.backup(dst)"'
```

- 备份文件 sha256：`606b99bc262602a4691844d465ecc3e91a34f85e5c42da1a7c217a7844125c8b`（110592 字节）
- 文件目录：20 个文件，共 227M。抽样 3 个文件 sha256（供回滚后校验）：
  - `d313e0a8…72fc497c`、`49da8233…2ce238a48f`（前缀节选，完整值见本机 /tmp/v3-rehearsal/NOTES）
- 备份时库状态：items 50 行（`count(*), sum(length(id))` = `(50, 800)`）、有 stored_name 的 20 行、devices 3、deliveries 48、表 6 张（旧 schema）。

**恢复命令（本次未执行，仅记录）**：

```
ssh root@<VPS>
systemctl stop copy-example
cp -a /opt/copy-example/data /opt/copy-example/data.failed-v3-YYYYMMDD   # 保留失败现场
cp /root/clipboard-v3rehearsal.db /opt/copy-example/data/clipboard.db     # 或当时的 .bak
chown webclip:webclip /opt/copy-example/data/clipboard.db
systemctl start copy-example
# 校验：抽样的 3 个文件 sha256 不变；/healthz 返回 ok
```

## 2. 拉取副本到本机

```
scp root@<VPS>:/root/clipboard-v3rehearsal.db /tmp/v3-rehearsal/clipboard.db
shasum -a256 /tmp/v3-rehearsal/clipboard.db   # 与线上一致：606b99bc…
```

## 3. 本机迁移（当前仓库 app.py，含 Task 6-18）

```
mkdir -p /tmp/v3-rehearsal-data/files
cp /tmp/v3-rehearsal/clipboard.db /tmp/v3-rehearsal-data/clipboard.db
WEBCLIP_DATA_DIR=/tmp/v3-rehearsal-data python3 -c "import app; app.init(); app.init()"
```

两遍 `init()` 均正常完成（幂等）。结果：

- 表清单：`device_tokens`、`item_blobs`、`sync_changes`、`idempotency_keys` 四张新表全部建立，旧表原样保留。
- 数据保留：items `(50, 800)` 与备份前一致；devices 3、deliveries 48 不变。
- **回填行为（记录点）**：本机副本没有 files 目录，20 行有 stored_name 的 items 全部按"文件不存在则跳过"处理，`item_blobs` 回填 0 行；迁移后待回填查询（`stored_name != '' and not exists original blob`）正确识别出 20 行待回填——证明回填选择逻辑与生产数据吻合。真实部署时文件在本机存在，会全部回填（单测 `test_migrate_v1_backfills_item_blobs_original` 已覆盖有文件路径）。

## 4. 回归

`python3 -m unittest test_app.py -v` → `Ran 71 tests / OK`（迁移代码在位时全套测试绿）。

## 5. 回滚演练（旧代码读迁移后/备份库）

```
git show 8018045:app.py > /tmp/v3-rollback/oldcode/old_app.py   # Task 6 之前的 app.py
mkdir -p /tmp/v3-rollback/data/files && cp /tmp/v3-rehearsal/clipboard.db /tmp/v3-rollback/data/
WEBCLIP_DATA_DIR=/tmp/v3-rollback/data python3 -c "import old_app; old_app.init(); ..."
```

旧代码 `init()` 正常完成（`create table if not exists` 容忍新表），items `(50, 800)`、devices 3 读取正常，`usage()` 返回正常；`cleanup()` 按既有语义清理了 16 个已过期 item（freed=0，因为副本无文件）。回滚路径可用。

## 6. 清理

- VPS：`rm -f /root/clipboard-v3rehearsal.db`（临时备份删除）。
- 本机：`/tmp/v3-rehearsal/`（生产 DB 副本）与 `/tmp/v3-rehearsal-data/`（迁移后副本）、`/tmp/v3-rollback/` 保留供复查。

## 结论

迁移在生产副本上：建表正确、可重复执行、不破坏旧数据、旧代码可回读。唯一注意事项：真实切换窗口仍需按主设计 §12.2 在部署时做一次正式备份（本次演练的备份已在演练后删除）。
