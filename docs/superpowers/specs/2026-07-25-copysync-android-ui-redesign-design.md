# CopySync 安卓 App（APK）UI 对齐 web + 三端传输改造落地（V2 预览定稿）设计文档

日期：2026-07-25
状态：V2 预览已发用户确认流程中（android-ui-v2.html）
前置：P1（web 端）已完成并上线，后端接口（续期/转存/transfer_history/默认 TTL）已就绪

## 一、需求提炼

### 范围
安卓 APK = 原生壳（MainActivity.java：底栏、下拉刷新、分享接收、下载管理、原生桥）
+ WebView 内容（app.py 的 `?app=android` 界面：androidAppHtml + android 专属 CSS/JS）。
本轮把安卓端 UI 对齐 web 方案 B，并落地 spec 中「三端都改」的传输改造。

### A. 底栏导航（原生）
1. 四栏改为：**收件箱 / 发送 / 网盘 / 设置**；「设备」栏移除（设备列表入口取消）。
2. 图标全部换线条风 SVG（现为文字色块 ▰/➤/▣/⚙）：收件箱=托盘、发送=纸飞机、
   网盘=云朵、设置=齿轮；以 vector drawable 实现，着色墨绿/灰两态。

### B. 发送页（WebView 主页）
3. 「发送到」**默认 Mac**，删除「全部设备」（三端规则：网页→Android、Android→Mac、Mac→Android）。
4. 保留时间默认 **1 天**（4h/1d/3d/7d 可选），到期自动删除；文案「网页自动保留记录」。
5. 三个快捷操作图标（粘贴文本/选文件/选照片）换精修线条图标。
6. 下方保留「传输记录」区块（含已过期灰显记录，数据来自 P1 的 history）。

### C. 收件箱页（WebView）
7. 纯收件列表：**没有「上传文件」按钮**；每行 = 图标 + 名称 + 来源/剩余时间 +
   行内操作「**上传** · 下载（文本为复制）」；「上传」= 调 `/api/items/<id>/keep` 转存网盘。
8. 点按行 = 接收/复制（现有原生接收链路 CopySyncNative.receiveFile 等全部保留）。
9. 底部带「传输记录」区块。

### D. 网盘页（WebView，新）
10. web 临时网盘的手机版：拖放上传框 + 上传按钮、搜索、筛选 chips（全部/文本/文件/图片/已固定）、
    每行前置钉子（钉住=斜钉墨绿、未钉=-45° 灰半透明，点击切换）、
    行内「续期 · 复制 · 下载 · ✕」、容量行「默认保存 7 天」、清理入口。
11. 行为与 web 完全一致：续期 +7 天（/extend）、钉住永久、默认 7 天 TTL。

### E. 视觉与交互
12. 整体对齐 web 方案 B：米白底 `#faf9f7`、白卡片、1px `#eee9e2` 边、14px 圆角、
    墨绿 `#0b5c3e`、柔和阴影；文件/图片/文本图标全部线条风。
13. **所有按钮有反馈**：Android 上以 pressed 态呈现（按下变深 + 下沉/缩放 + 涟漪或透明度过渡），
    禁用态灰化；覆盖主按钮、chips、行内操作、底栏 tab、钉子、快捷操作卡片。
14. **下拉刷新更流畅（重点视觉）**：
    - 现状：下拉 >96dp 松手 → Toast「正在刷新…」+ webView.reload()（整页白闪）。
    - 改为：顶部出现跟随手指的下拉指示器（圆形箭头/进度环，带阻尼位移与旋转动画，
      过阈值变色提示松手）；松手后指示器停留并转圈；
      刷新改为 **JS 软刷新**（调用页面内 refreshAll：重新拉取 items/transfers/devices/usage，
      不再整页 reload、无白闪）；完成后指示器收回 + 轻提示（glass toast「已刷新」）。

### 明确不做（YAGNI）
- 不改分享接收、后台同步模式、下载管理、原生桥接口、设置页功能
- 不改 Mac App（P3 另起）
- 不新增后端接口（复用 P1 全部接口）
- 设备管理入口不做替代品（用户确认移除）

## 二、验收标准

### 代码与构建
1. `python3 test_app.py` 全部通过（android HTML 相关断言按新界面同步更新，只改断言不改测试逻辑）。
2. `gradlew assembleDebug` 与 `lintDebug` 通过；versionCode/versionName 递增。
3. app.py 改动不破坏 web / `?app=mac` 两种模式（截图核对）。

### 界面核对（?app=android，手机宽度截图逐屏）
4. 发送页：默认「发送到：Mac」、无全部设备、TTL 默认 1 天、传输记录正常。
5. 收件箱页：无上传按钮；行内「上传」转存网盘成功（网盘页可见，默认 7 天）；
   点按接收/复制链路正常。
6. 网盘页：上传/搜索/筛选/钉子切换/续期/复制/下载/删除全部可用；与 web 网盘数据一致。
7. 底栏四栏切换正常、图标为线条风、选中态正确。
8. **与 V2 预览图一致，任何元素无重叠**（桌面/手机两宽度核对）。
9. 所有按钮按下有可见反馈。

### 下拉刷新
10. 三个页面顶部下拉均有跟随手指的指示器动画；松手软刷新、无整页白闪；
    数据确实更新（新增一条内容后下拉可见）。

### 发布与线上
11. 新 APK 与 `updates/android.json` 部署到 VPS `/opt/copy-example/updates`；
    `/api/update/android` 返回新版本号，公网 APK SHA256 与本地构建一致。
12. 线上 `?app=android` 实测三页功能正常；web 端与 Mac 端回归正常。
13. 交接 txt 更新（版本号、SHA256、行为变更、真机待确认项）。

### 真机（用户 Samsung 安装后确认）
14. 底栏图标显示、三页切换、下拉刷新动画流畅度、接收链路、转存网盘。

## 三、约束

1. **最终效果与 V2 预览图一模一样，任何元素不得重叠**（硬性约束）。
2. **所有按钮必须有反馈**（硬性约束）。
3. 功能不丢：分享接收、后台同步、下载管理、原生桥、设置页、SSE/轮询全部保留。
4. 原生改动集中在 MainActivity.java（+ 必要 drawable 资源）；WebView 改动集中在 app.py
   android 专属区块；不得破坏 web 与 `?app=mac`。
5. 不新增后端接口；数据库不动。
6. 版本号递增；旧版 APK 更新链路（/api/update/android）必须可用。
7. 发布走「本地构建 → 校验 SHA256 → 备份线上旧 APK → 替换 → 公网校验」流程。
8. 上线后更新 VPS 交接 txt 的 CopySync 段，遵循 vps-inventory-handoff-manager 规范。

## 四、参考

- 定稿预览：`.superpowers/brainstorm/92417-1784970466/content/android-ui-v2.html`（V2）
- 过程稿：同目录 `android-ui-v1.html`
- 用户 APK 现状截图：`~/Desktop/微信图片_20260725191716_329_1.jpg`
- P1 web 端设计文档：`docs/superpowers/specs/2026-07-25-copysync-web-ui-redesign-design.md`
- 下拉刷新现状代码：`android-copy/CopyWeb/app/src/main/java/xyz/copyweb/MainActivity.java:153-167`
