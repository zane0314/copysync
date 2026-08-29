const assert = require('node:assert/strict');
const { mkdtempSync, rmSync } = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const test = require('node:test');
const { chromium } = require('playwright');

const SHOT_DIR = path.join(__dirname, 'docs/superpowers/specs/assets/phase4');
// 保存 GUI 证据截图；失败绝不影响行为断言
async function shot(name) {
  try {
    await page.screenshot({ path: path.join(SHOT_DIR, name) });
  } catch (_) { /* 截图失败忽略 */ }
}

const password = 'phase4-web-test-password';
let baseUrl;
let browser;
let context;
let dataDir;
let page;
let server;
let targetToken;

async function freePort() {
  return await new Promise((resolve, reject) => {
    const socket = net.createServer();
    socket.once('error', reject);
    socket.listen(0, '127.0.0.1', () => {
      const { port } = socket.address();
      socket.close(() => resolve(port));
    });
  });
}

async function waitForServer(url) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      if ((await fetch(`${url}/healthz`)).ok) return;
    } catch (_) {}
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error('isolated app.py did not start');
}

async function api(pathname, options = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, options);
  const body = await response.json();
  assert.ok(response.ok, `${pathname}: ${JSON.stringify(body)}`);
  return body;
}

async function createExternalText(text) {
  return await api('/api/v1/items', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${targetToken}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': `web-ui-${text}`,
    },
    body: JSON.stringify({ kind: 'text', text, target_device: 'all' }),
  });
}

async function dismissOverlays() {
  // 关闭可能残留的预览浮层/更多菜单，避免拦截后续导航点击（测试间共享同一 page）
  const overlay = page.locator('#previewOverlay');
  if (await overlay.isVisible().catch(() => false)) {
    await page.locator('#previewClose').click().catch(() => {});
    await overlay.waitFor({ state: 'hidden' }).catch(() => {});
  }
  const menu = page.locator('#menu:not([hidden])');
  if (await menu.isVisible().catch(() => false)) {
    await page.keyboard.press('Escape').catch(() => {});
  }
}

async function go(view) {
  await dismissOverlays();
  await page.locator(`[data-view="${view}"]`).click();
  await page.locator(`#view-${view}`).waitFor({ state: 'visible' });
}

async function openItemMenu(title) {
  const row = page.locator('#driveList [data-item]').filter({ hasText: title });
  await row.locator('[data-act="menu"]').click();
  await page.locator('#menu:not([hidden])').waitFor();
}

// 列表每次改动都会异步 refreshAll 重渲染（显式调用 + SSE sync 事件），
// 会把纯客户端展开的备注框重建为 hidden。重试打开并保存，直到某个安静窗口成功。
async function setNote(title, noteText) {
  const row = page.locator('#driveList [data-item]').filter({ hasText: title });
  // 注意：.note-editor 是 [data-item] 文章节点的“兄弟”，不是子节点，
  // 需按条目 id 用 [data-note-for] 定位对应编辑器。
  const itemId = await row.getAttribute('data-item');
  const editor = page.locator(`#driveList .note-editor[data-note-for="${itemId}"]`);
  const input = editor.locator('input');
  const saveBtn = editor.locator('[data-act="note-save"]');
  for (let attempt = 0; attempt < 15; attempt += 1) {
    if (!(await input.isVisible().catch(() => false))) {
      await openItemMenu(title);
      await page.getByText('备注', { exact: true }).click();
    }
    try {
      await input.waitFor({ state: 'visible', timeout: 1000 });
    } catch (_) {
      continue; // 被重渲染冲掉，重开菜单
    }
    await input.fill(noteText);
    await saveBtn.click();
    try {
      await page.getByText('备注已保存').waitFor({ timeout: 2000 });
      return row;
    } catch (_) {
      continue; // 保存前被重渲染冲掉，重试
    }
  }
  throw new Error(`备注编辑器未能稳定保存：${title}`);
}

test.before(async () => {
  const port = await freePort();
  baseUrl = `http://127.0.0.1:${port}`;
  dataDir = mkdtempSync(path.join(os.tmpdir(), 'copysync-web-ui-'));
  server = spawn('python3', ['app.py'], {
    cwd: __dirname,
    env: {
      ...process.env,
      WEBCLIP_DATA_DIR: dataDir,
      WEBCLIP_DISK_HIGH_WATER: '1',
      WEBCLIP_HOST: '127.0.0.1',
      WEBCLIP_PORT: String(port),
      WEBCLIP_PASSWORD: password,
      WEBCLIP_SESSION_SECRET: 'phase4-web-test-session-secret',
      WEBCLIP_COOKIE_SECURE: '0',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForServer(baseUrl);

  const target = await api('/api/v1/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      password,
      device_name: 'Phase4 Android Target',
      platform: 'android',
    }),
  });
  targetToken = target.token;

  browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  context = await browser.newContext({ acceptDownloads: true });
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: baseUrl });
  page = await context.newPage();
  await page.goto(baseUrl, { waitUntil: 'networkidle' });
  await page.locator('#loginPassword').fill(password);
  await page.locator('#loginBtn').click();
  await page.locator('#appShell').waitFor({ state: 'visible' });
});

test.after(async () => {
  await browser?.close();
  server?.kill('SIGTERM');
  rmSync(dataDir, { recursive: true, force: true });
});

test('拖拽上传和剪贴板粘贴发送走真实浏览器事件', async () => {
  const transfer = await page.evaluateHandle(() => {
    const data = new DataTransfer();
    data.items.add(new File(['drag-body'], 'phase4-drag.txt', { type: 'text/plain' }));
    return data;
  });
  await page.dispatchEvent('#dropZone', 'drop', { dataTransfer: transfer });
  await page.getByText('已上传 phase4-drag.txt').waitFor();

  await page.evaluate(() => navigator.clipboard.writeText('phase4-paste-text'));
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), 'phase4-paste-text');
  await page.locator('#pasteBtn').click();
  await page.waitForFunction(() =>
    document.querySelector('#composerText').value === 'phase4-paste-text');
  await page.locator('#sendBtn').click();
  await page.getByText('已加入发送队列').waitFor();
});

test('搜索筛选与图钉备注续期删除均更新真实列表', async () => {
  await createExternalText('phase4-list-actions');
  await go('drive');
  const listItems = (await api('/api/v1/items', {
    headers: { Authorization: `Bearer ${targetToken}` },
  })).items.filter(item => item.text === 'phase4-list-actions');
  assert.equal(listItems.length, 1);
  await page.locator('#driveList').getByText('phase4-list-actions').waitFor();

  await page.locator('#searchInput').fill('phase4-list-actions');
  assert.equal(await page.locator('#driveList [data-item]').count(), 1);
  await page.locator('#searchInput').fill('');
  await page.locator('#filters [data-kind="text"]').click();
  assert.ok((await page.locator('#driveList [data-item]').count()) >= 1);
  await page.locator('#filters [data-kind=""]').click();

  await openItemMenu('phase4-list-actions');
  await page.getByText('图钉固定（永久保留）').click();
  await page.getByText('已固定，永久保留').waitFor();
  await openItemMenu('phase4-list-actions');
  await page.getByText('取消图钉').click();
  await page.getByText('已取消图钉').waitFor();
  await openItemMenu('phase4-list-actions');
  await page.getByText('续期 7 天').click();
  await page.getByText('已续期 7 天').waitFor();
  const row = await setNote('phase4-list-actions', 'phase4-web-note');
  assert.match(await row.locator('.row-sub').textContent(), /phase4-web-note/);

  page.once('dialog', dialog => dialog.accept());
  await openItemMenu('phase4-list-actions');
  await page.getByText('删除', { exact: true }).click();
  await page.getByText('已删除').waitFor();
  // 删除后 toast 先于 refreshAll 重渲染出现，需等该行真正从列表移除再断言
  await page.locator('#driveList [data-item]').filter({ hasText: 'phase4-list-actions' })
    .waitFor({ state: 'detached' });
  assert.equal(await page.locator('#driveList').getByText('phase4-list-actions').count(), 0);
});

test('传输记录点击复制，网盘文本/文件/图片行执行对应动作', async () => {
  await go('transfers');
  const transferRow = page.locator('#transferList [data-transfer]').filter({ hasText: 'phase4-paste-text' });
  await transferRow.waitFor();
  await transferRow.click();
  await page.getByText('文本已复制').waitFor();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), 'phase4-paste-text');

  await createExternalText('phase4-drive-text-click');
  await page.locator('#driveFiles').setInputFiles({
    name: 'phase4-drive-file.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('file-click'),
  });
  await page.getByText('已上传 phase4-drive-file.txt').waitFor();
  await page.locator('#driveFiles').setInputFiles({
    name: 'phase4-drive-image.png',
    mimeType: 'image/png',
    buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64'),
  });
  await page.getByText('已上传 phase4-drive-image.png').waitFor();
  await go('drive');

  await page.locator('#driveList').getByText('phase4-drive-text-click').click();
  await page.getByText('已复制').waitFor();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), 'phase4-drive-text-click');
  await shot('web-drive-text-click-copy.png');

  const downloadPromise = page.waitForEvent('download');
  await page.locator('#driveList [data-item]').filter({ hasText: 'phase4-drive-file.txt' }).click();
  assert.match((await downloadPromise).suggestedFilename(), /phase4-drive-file\.txt/);

  await page.locator('#driveList [data-item]').filter({ hasText: 'phase4-drive-image.png' }).click();
  await page.locator('#previewOverlay').waitFor({ state: 'visible' });
  await shot('web-drive-image-preview.png');
  // 关闭预览，避免浮层残留拦截后续测试的导航点击
  await page.locator('#previewClose').click();
  await page.locator('#previewOverlay').waitFor({ state: 'hidden' });
});

test('SSE 在不点击刷新时把外部条目推入当前网盘列表', async () => {
  await go('drive');
  assert.equal(await page.locator('#driveList').getByText('phase4-web-sse-final').count(), 0);
  await shot('web-sse-before.png');
  await createExternalText('phase4-web-sse-final');
  // 未点刷新、未切页，仅靠 SSE sync 事件把外部条目推入当前列表
  await page.locator('#driveList').getByText('phase4-web-sse-final').waitFor({ timeout: 5000 });
  await shot('web-sse-after.png');
});
