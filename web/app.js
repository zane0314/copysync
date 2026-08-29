'use strict';
/* CopySync 网页客户端：原生 JS，无框架无构建；仅调 /api/v1，Cookie webclip_v1 承载认证。 */
const BUILD = '20260828d';
console.log('CopySync build', BUILD);

const $ = id => document.getElementById(id);

const state = {
  deviceId: localStorage.getItem('copysync.deviceId') || '',
  devices: [],
  items: [],
  deliveries: [],
  history: [],
  usage: null,
  view: 'inbox',
  filter: '',
  pendingFiles: [],
  idemKey: null,
  sending: false,
  refreshing: false,
  events: null,
};

// Mac 端 app 通过 WKWebView 加载本站并带 ?app=mac；据此把设备登记为 Mac 端，
// 与网页浏览器区分开（此前两者都以 网页浏览器/web 登录，会合并成同一条设备记录）。
const IS_MAC_APP = new URLSearchParams(location.search).get('app') === 'mac';
const DEVICE_NAME = IS_MAC_APP ? 'Mac端' : '网页浏览器';
const DEVICE_PLATFORM = IS_MAC_APP ? 'mac' : 'web';
const EXTEND_TTL = 7 * 86400;

/* ---------- 基础工具 ---------- */

const escapeHtml = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const fmtSize = n => n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(1) + ' KB'
  : n < 1073741824 ? (n / 1048576).toFixed(1) + ' MB' : (n / 1073741824).toFixed(2) + ' GB';

function fmtTime(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  if (sameDay) return d.toTimeString().slice(0, 5);
  if (d.toDateString() === yesterday.toDateString()) return '昨天';
  const days = Math.floor((now - d) / 86400000);
  if (days < 7) return `${days} 天前`;
  return d.toLocaleDateString();
}

function fmtExpire(item) {
  if (item.pinned) return '永久';
  if (!item.expires_at) return '永久';
  const s = item.expires_at - Date.now() / 1000;
  if (s <= 0) return '已到期';
  if (s < 3600) return `剩 ${Math.max(1, Math.round(s / 60))} 分钟`;
  if (s < 86400) return `剩 ${Math.round(s / 3600)} 小时`;
  return `剩 ${Math.round(s / 86400)} 天`;
}

const newIdemKey = () => (crypto.randomUUID ? crypto.randomUUID()
  : `k${Date.now()}-${Math.random().toString(36).slice(2)}`);

let toastTimer;
function toast(message, isError = false) {
  const el = $('toast');
  el.textContent = message;
  el.classList.toggle('error', isError);
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 3000);
}

/* ---------- 线性图标 ---------- */

const ICON_PATHS = {
  inbox: '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
  history: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  drive: '<path d="M17.5 19a4.5 4.5 0 0 0 .42-8.98 6.5 6.5 0 0 0-12.6 1.62A4 4 0 0 0 6 19h11.5z"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h.01a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/>',
  upload: '<path d="M4 14.9A7 7 0 1 1 15.7 8h1.8a4.5 4.5 0 0 1 2.5 8.2"/><path d="M12 12v9"/><path d="m16 16-4-4-4 4"/>',
  sendto: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
  paste: '<path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/>',
  file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.5-3.5a2 2 0 0 0-3 0L6 20"/>',
  text: '<path d="M4 7V5h16v2M9 20h6M12 5v15"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 21h16"/>',
  more: '<circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>',
  pin: '<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16h14v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V5h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1z"/>',
  note: '<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  extend: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/><path d="M19 3v4h-4"/>',
  trash: '<path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/>',
  send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
};

const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS[name] || ''}</svg>`;

function hydrateIcons(root = document) {
  root.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });
}

/* ---------- API ---------- */

async function api(path, opts = {}) {
  let resp;
  try {
    resp = await fetch(path, { cache: 'no-store', ...opts });
  } catch (err) {
    throw new Error('网络连接失败，请检查网络后重试');
  }
  const text = await resp.text();
  let data = null;
  if (text) { try { data = JSON.parse(text); } catch { data = null; } }
  if (!resp.ok) {
    const message = (data && data.error && data.error.message) || `请求失败（HTTP ${resp.status}）`;
    if (resp.status === 401 && !path.startsWith('/api/v1/auth/login')) {
      const code = data && data.error && data.error.code;
      // invalid_credentials 是修改密码等表单的可展示输入错误，不是会话失效；
      // 仅 token 失效/未认证才强制回登录页。
      if (code !== 'invalid_credentials') {
        showLogin();
        throw new Error('登录已失效，请重新登录');
      }
    }
    throw new Error(message);
  }
  return data || {};
}

/* ---------- 登录 / 退出 ---------- */

function showLogin() {
  $('appShell').hidden = true;
  $('loginView').hidden = false;
  if (state.events) { state.events.close(); state.events = null; }
}

function showApp() {
  $('loginView').hidden = true;
  $('appShell').hidden = false;
}

async function login(password) {
  const data = await api('/api/v1/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password, device_name: DEVICE_NAME, platform: DEVICE_PLATFORM, client: 'web' }),
  });
  state.deviceId = data.device.id;
  localStorage.setItem('copysync.deviceId', state.deviceId);
}

async function logout() {
  const btn = $('logoutBtn');
  btn.disabled = true;
  btn.textContent = '退出中…';
  try {
    await api('/api/v1/auth/logout', { method: 'POST' });
  } catch (err) {
    toast('退出失败：' + err.message, true);
    btn.disabled = false;
    btn.textContent = '退出登录';
    return;
  }
  localStorage.removeItem('copysync.deviceId');
  state.deviceId = '';
  btn.disabled = false;
  btn.textContent = '退出登录';
  showLogin();
}

/* ---------- 数据加载 ---------- */

async function loadDevices() {
  const data = await api('/api/v1/devices');
  state.devices = data.devices || [];
  if (!state.deviceId) {
    const found = state.devices.find(d => d.platform === DEVICE_PLATFORM && d.name === DEVICE_NAME);
    if (found) {
      state.deviceId = found.id;
      localStorage.setItem('copysync.deviceId', found.id);
    }
  }
  const online = state.devices.filter(d => d.online).length;
  $('onlineCount').textContent = `${online} 台设备在线`;
  const mine = state.devices.find(d => d.id === state.deviceId);
  // 旧版 Mac app 曾以 网页浏览器/web 登录；升级后一次性纠正为 Mac 端身份。
  if (IS_MAC_APP && mine && mine.platform !== 'mac') {
    localStorage.removeItem('copysync.deviceId');
    state.deviceId = '';
    await api('/api/v1/auth/logout', { method: 'POST' }).catch(() => {});
    toast('检测到旧的网页身份，请重新登录一次以标识为 Mac 端');
    showLogin();
    return;
  }
  $('settingsDevice').textContent = mine ? `${mine.name}（${mine.platform}）` : DEVICE_NAME;
  const select = $('targetDevice');
  const previous = select.value;
  const targets = state.devices.filter(d => d.id !== state.deviceId && d.id !== 'web' && d.id !== 'windows');
  select.innerHTML = targets.length
    ? targets.map(d => `<option value="${escapeHtml(d.id)}">发送到：${escapeHtml(d.name)}${d.online ? ' · 在线' : ' · 离线'}</option>`).join('')
    : '<option value="">暂无其他设备</option>';
  if ([...select.options].some(o => o.value === previous)) select.value = previous;
}

async function loadItems() {
  const data = await api('/api/v1/items');
  state.items = data.items || [];
}

async function loadDeliveries() {
  const data = await api('/api/v1/deliveries');
  state.deliveries = data.deliveries || [];
  state.history = data.history || [];
}

async function loadUsage() {
  state.usage = await api('/api/v1/usage');
}

async function heartbeat() {
  if (!state.deviceId) return;
  try {
    await api(`/api/v1/devices/${encodeURIComponent(state.deviceId)}/heartbeat`, { method: 'POST' });
  } catch { /* 心跳失败不打扰用户，下一轮自动重试 */ }
}

async function refreshAll() {
  await Promise.all([loadItems(), loadDeliveries(), loadDevices(), loadUsage()]);
  renderAll();
}

async function refreshNow(button) {
  if (state.refreshing) return;
  state.refreshing = true;
  const old = button.innerHTML;
  button.disabled = true;
  button.textContent = '刷新中…';
  try {
    await refreshAll();
    setNetBanner('');
    button.textContent = '已刷新';
  } catch (err) {
    button.innerHTML = old;
    setNetBanner('刷新失败：' + err.message);
  } finally {
    state.refreshing = false;
    setTimeout(() => { button.innerHTML = old; }, 1200);
  }
}

function setNetBanner(message) {
  $('netBanner').hidden = !message;
  if (message) $('netBannerText').textContent = message;
}

/* ---------- 实时通知 ---------- */

function connectEvents() {
  if (state.events) state.events.close();
  const es = new EventSource('/api/v1/events');
  state.events = es;
  es.addEventListener('sync', () => refreshAll().catch(() => {}));
  es.onopen = () => {
    document.querySelector('.dot').classList.remove('off');
    setNetBanner('');
  };
  es.onerror = () => {
    document.querySelector('.dot')?.classList.add('off');
    setNetBanner('实时连接已断开，正在自动重连…');
  };
}

/* ---------- 视图渲染 ---------- */

function deviceName(id) {
  const d = state.devices.find(x => x.id === id);
  if (d) return d.name;
  return { web: '网页', mac: 'Mac', android: 'Android 手机', all: '全部设备' }[id] || id || '未知设备';
}

function isImage(item) {
  return item.kind === 'image' || ((item.mime || '').startsWith('image/') && item.mime !== 'image/svg+xml');
}

function itemTitle(item) {
  return item.kind === 'text' ? (item.text || '文本').split('\n')[0] : (item.name || '文件');
}

function rowIconHtml(item) {
  if (isImage(item)) {
    return `<img src="/api/v1/items/${encodeURIComponent(item.id)}/content?variant=clipboard&inline=1" alt="" loading="lazy" onerror="this.onerror=null;this.src='/api/v1/items/${encodeURIComponent(item.id)}/content?variant=original&inline=1'">`;
  }
  return icon(item.kind === 'text' ? 'text' : 'file');
}

function setView(view) {
  state.view = view;
  document.querySelectorAll('.nav-item').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  ['inbox', 'transfers', 'drive', 'settings'].forEach(v => { $(`view-${v}`).hidden = v !== view; });
  renderAll();
}

function renderAll() {
  if ($('appShell').hidden) return;
  renderInbox();
  renderTransfers();
  renderDrive();
}

function renderInbox() {
  const list = $('inboxList');
  const rows = state.deliveries.slice(0, 12);
  list.innerHTML = rows.length
    ? rows.map(t => transferRowHtml(t, false)).join('')
    : '<div class="empty">这里还没有内容</div>';
  // 未读仅计本端“接收”的等待项（入站）；我发出的（出站）不算未读，不参与“全部已读”
  const waiting = state.deliveries.filter(t => t.status === 'waiting' && t.target_device === state.deviceId).length;
  $('inboxBadge').hidden = !waiting;
  $('inboxBadge').textContent = waiting;
  const mb = $('markAllReadBtn');
  if (mb) { mb.hidden = !waiting; mb.textContent = waiting ? `全部已读（${waiting}）` : '全部已读'; }
}

async function markAllRead() {
  // 一键已读：只标记本端“接收”的等待项为已读（入站 ack）；不触碰出站发送的消息
  const mine = state.deliveries.filter(t => t.status === 'waiting' && t.target_device === state.deviceId);
  if (!mine.length) { toast('没有未读内容'); return; }
  const btn = $('markAllReadBtn');
  if (btn) { btn.disabled = true; btn.textContent = '清理中…'; }
  let done = 0;
  for (const t of mine) {
    await ackDelivery(t, 'delivered');
    done++;
  }
  if (btn) btn.disabled = false;
  toast(`已标记 ${done} 条已读`);
  await refreshAll().catch(() => {});
}

function renderTransfers() {
  const live = state.deliveries.map(t => ({ ...t, expired: false }));
  const gone = state.history.map(t => ({ ...t, expired: true }));
  const rows = [...live, ...gone].sort((a, b) => b.created_at - a.created_at);
  $('transferList').innerHTML = rows.length
    ? rows.map(t => transferRowHtml(t, t.expired)).join('')
    : '<div class="empty">暂无记录</div>';
}

const STATUS_LABELS = { waiting: '等待接收', delivered: '已送达', downloaded: '已接收', copied: '已接收', failed: '失败', cancelled: '已取消' };

function transferRowHtml(t, expired) {
  const kind = t.kind || (t.text ? 'text' : 'file');
  const iconHtml = !expired && isImage({ kind, mime: t.mime })
    ? `<img src="/api/v1/items/${encodeURIComponent(t.item_id)}/content?variant=clipboard&inline=1" alt="" loading="lazy" onerror="this.onerror=null;this.src='/api/v1/items/${encodeURIComponent(t.item_id)}/content?variant=original&inline=1'">`
    : icon(kind === 'text' ? 'text' : isImage({ kind, mime: t.mime }) ? 'image' : 'file');
  const title = kind === 'text' ? (t.text || '文本').split('\n')[0] : (t.name || '文件');
  const status = expired
    ? '<span class="status expired">已过期 · 文件已删</span>'
    : `<span class="status ${escapeHtml(t.status)}">${STATUS_LABELS[t.status] || escapeHtml(t.status)}</span>`;
  const primary = kind === 'text'
    ? `<button type="button" class="icon-btn" data-act="copy-transfer" data-id="${escapeHtml(t.id)}" title="复制">${icon('copy')}</button>`
    : `<button type="button" class="icon-btn" data-act="receive-transfer" data-id="${escapeHtml(t.id)}" title="接收 / 重新下载">${icon('download')}</button>`;
  return `<article class="row ${expired ? 'expired' : 'clickable'}" data-transfer="${escapeHtml(t.id)}" data-expired="${expired ? 1 : 0}">
    <div class="row-icon k-${kind === 'text' ? 'text' : isImage({ kind, mime: t.mime }) ? 'image' : 'file'}">${iconHtml}</div>
    <div class="row-main">
      <div class="row-title" title="${escapeHtml(title)}">${escapeHtml(title)}</div>
      <div class="row-sub">${escapeHtml(deviceName(t.source_device))} → ${escapeHtml(deviceName(t.target_device))} · ${status}</div>
    </div>
    <div class="row-meta">${fmtTime(t.created_at)}${t.size ? '<br>' + fmtSize(t.size) : ''}</div>
    <div class="row-actions">${expired ? '' : primary}</div>
  </article>`;
}

function renderDrive() {
  const u = state.usage;
  if (u) {
    $('usageLine').textContent = `临时 ${fmtSize(u.temp_bytes)} / ${fmtSize(u.limits.temp)} · 固定 ${fmtSize(u.pinned_bytes)}`;
  }
  const q = ($('searchInput').value || '').trim().toLowerCase();
  const visible = state.items.filter(i => {
    const hay = `${i.name || ''} ${i.text || ''} ${i.note || ''}`.toLowerCase();
    if (q && !hay.includes(q)) return false;
    if (state.filter === 'text') return i.kind === 'text';
    if (state.filter === 'image') return isImage(i);
    if (state.filter === 'file') return i.kind !== 'text' && !isImage(i);
    if (state.filter === 'pinned') return !!i.pinned;
    return true;
  });
  $('driveList').innerHTML = visible.length
    ? visible.map(itemRowHtml).join('')
    : '<div class="empty">这里还没有内容</div>';
}

function itemRowHtml(item) {
  const title = itemTitle(item);
  const note = item.note ? ` · 备注：${item.note}` : '';
  const sub = `来自 ${deviceName(item.source_device)} · ${fmtExpire(item)}${note}`;
  return `<article class="row clickable" data-item="${escapeHtml(item.id)}">
    <div class="row-icon k-${item.kind === 'text' ? 'text' : isImage(item) ? 'image' : 'file'}">${rowIconHtml(item)}</div>
    <div class="row-main">
      <div class="row-title" title="${escapeHtml(title)}">${item.pinned ? '<span class="pin-flag">📌 </span>' : ''}${escapeHtml(title)}</div>
      <div class="row-sub" title="${escapeHtml(sub)}">${escapeHtml(sub)}</div>
    </div>
    <div class="row-meta">${fmtTime(item.created_at)}<br>${fmtSize(item.size)}</div>
    <div class="row-actions">
      <button type="button" class="icon-btn" data-act="copy" data-id="${escapeHtml(item.id)}" title="复制">${icon('copy')}</button>
      <button type="button" class="icon-btn" data-act="download" data-id="${escapeHtml(item.id)}" title="下载">${icon('download')}</button>
      <button type="button" class="icon-btn" data-act="menu" data-id="${escapeHtml(item.id)}" title="更多" aria-haspopup="menu">${icon('more')}</button>
    </div>
  </article>
  <div class="note-editor" data-note-for="${escapeHtml(item.id)}" hidden>
    <input type="text" maxlength="200" placeholder="备注（200 字以内）" value="${escapeHtml(item.note || '')}">
    <button type="button" class="btn small" data-act="note-save" data-id="${escapeHtml(item.id)}">保存</button>
    <button type="button" class="btn small soft" data-act="note-cancel">取消</button>
  </div>`;
}

/* ---------- 更多菜单 ---------- */

function closeMenu() { $('menu').hidden = true; }

function openMenu(anchor, entries) {
  const menu = $('menu');
  menu.innerHTML = entries.map((e, i) =>
    `<button type="button" data-menu-idx="${i}" class="${e.danger ? 'danger' : ''}"><span class="btn-icon">${icon(e.icon)}</span>${e.label}</button>`
  ).join('');
  menu.hidden = false;
  const rect = anchor.getBoundingClientRect();
  const mw = menu.offsetWidth, mh = menu.offsetHeight;
  menu.style.left = Math.max(8, Math.min(rect.right - mw, innerWidth - mw - 8)) + 'px';
  menu.style.top = (rect.bottom + mh + 8 > innerHeight ? rect.top - mh - 6 : rect.bottom + 6) + 'px';
  menu.querySelectorAll('button').forEach(btn => {
    btn.onclick = () => { closeMenu(); entries[Number(btn.dataset.menuIdx)].run(); };
  });
}

function itemMenu(anchor, item) {
  const entries = [];
  const target = $('targetDevice').value;
  if (target) {
    entries.push({ icon: 'send', label: `发送到 ${deviceName(target)}`, run: () => sendExisting(item, target) });
  }
  entries.push({
    icon: 'pin', label: item.pinned ? '取消图钉' : '图钉固定（永久保留）',
    run: () => patchItem(item, { pinned: !item.pinned }, item.pinned ? '已取消图钉' : '已固定，永久保留'),
  });
  if (!item.pinned) {
    entries.push({ icon: 'extend', label: '续期 7 天', run: () => patchItem(item, { ttl: EXTEND_TTL }, '已续期 7 天') });
  }
  entries.push({ icon: 'note', label: '备注', run: () => toggleNoteEditor(item.id) });
  entries.push({
    icon: 'trash', label: '删除', danger: true,
    run: () => {
      if (confirm(item.pinned ? '这是已钉住内容，确认删除？' : '删除这条内容？')) deleteItem(item);
    },
  });
  openMenu(anchor, entries);
}

/* ---------- 条目操作 ---------- */

function findItem(id) { return state.items.find(i => i.id === id); }

async function withButton(button, doing, work) {
  if (button.disabled) return;
  const old = button.innerHTML;
  button.disabled = true;
  button.textContent = doing;
  try {
    await work();
  } finally {
    setTimeout(() => { button.disabled = false; button.innerHTML = old; }, 600);
  }
}

async function patchItem(item, fields, okMessage) {
  try {
    await api(`/api/v1/items/${encodeURIComponent(item.id)}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': newIdemKey() },
      body: JSON.stringify(fields),
    });
    toast(okMessage);
    await refreshAll();
  } catch (err) {
    toast('操作失败：' + err.message, true);
  }
}

async function deleteItem(item) {
  try {
    await api(`/api/v1/items/${encodeURIComponent(item.id)}`, {
      method: 'DELETE',
      headers: { 'Idempotency-Key': newIdemKey() },
    });
    toast('已删除');
    await refreshAll();
  } catch (err) {
    toast('删除失败：' + err.message, true);
  }
}

function toggleNoteEditor(itemId) {
  const editor = document.querySelector(`[data-note-for="${CSS.escape(itemId)}"]`);
  if (!editor) return;
  editor.hidden = !editor.hidden;
  if (!editor.hidden) editor.querySelector('input').focus();
}

async function saveNote(button, itemId) {
  const editor = button.closest('.note-editor');
  const note = editor.querySelector('input').value.trim();
  await withButton(button, '保存中…', async () => {
    try {
      await api(`/api/v1/items/${encodeURIComponent(itemId)}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json', 'Idempotency-Key': newIdemKey() },
        body: JSON.stringify({ note }),
      });
      toast('备注已保存');
      editor.hidden = true;
      await refreshAll();
    } catch (err) {
      toast('备注保存失败：' + err.message, true);
    }
  });
}

/* ---------- 复制 / 下载 / 预览 ---------- */

async function copyTextToClipboard(text) {
  try {
    await navigator.clipboard.writeText(String(text ?? ''));
  } catch {
    const field = document.createElement('textarea');
    field.value = String(text ?? '');
    field.style.position = 'fixed';
    field.style.opacity = '0';
    document.body.appendChild(field);
    field.select();
    document.execCommand('copy');
    field.remove();
  }
}

async function copyItem(item) {
  try {
    if (item.kind === 'text') {
      await copyTextToClipboard(item.text || '');
    } else if (isImage(item)) {
      // 优先通用剪贴板变体（PNG/JPEG），缺失时回退原件
      let resp = await fetch(`/api/v1/items/${encodeURIComponent(item.id)}/content?variant=clipboard`, { cache: 'no-store' });
      if (resp.status === 404) {
        resp = await fetch(`/api/v1/items/${encodeURIComponent(item.id)}/content?variant=original`, { cache: 'no-store' });
      }
      if (!resp.ok) throw new Error('读取图片内容失败');
      let blob = await resp.blob();
      if (blob.type !== 'image/png') {
        const bitmap = await createImageBitmap(blob);
        const canvas = document.createElement('canvas');
        canvas.width = bitmap.width;
        canvas.height = bitmap.height;
        canvas.getContext('2d').drawImage(bitmap, 0, 0);
        blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
      }
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
    } else {
      // v1 暂无签名公开链接，复制需登录会话的内容地址
      await copyTextToClipboard(`${location.origin}/api/v1/items/${encodeURIComponent(item.id)}/content`);
    }
    toast('已复制');
  } catch (err) {
    toast('复制失败：' + err.message, true);
  }
}

function downloadItem(item) {
  const link = document.createElement('a');
  link.href = `/api/v1/items/${encodeURIComponent(item.id)}/content?variant=original`;
  link.download = item.kind === 'text' ? 'clipboard.txt' : (item.name || 'CopySync-download');
  document.body.appendChild(link);
  link.click();
  link.remove();
  toast('已开始下载 ' + (item.name || '文件'));
}

function previewImage(item) {
  const overlay = $('previewOverlay');
  const img = $('previewImg');
  img.onerror = () => {
    img.onerror = null;
    img.src = `/api/v1/items/${encodeURIComponent(item.id)}/content?variant=original&inline=1`;
  };
  img.src = `/api/v1/items/${encodeURIComponent(item.id)}/content?variant=clipboard&inline=1`;
  overlay.hidden = false;
}

/* ---------- 传输记录：点击复制 / 重收 ---------- */

function findDelivery(id) {
  return state.deliveries.find(t => t.id === id) || state.history.find(t => t.id === id);
}

async function ackDelivery(transfer, status) {
  if (transfer.target_device !== state.deviceId) return; // 只能由目标设备确认
  try {
    await api(`/api/v1/deliveries/${encodeURIComponent(transfer.id)}/ack`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': newIdemKey() },
      body: JSON.stringify({ status }),
    });
  } catch { /* ack 失败不影响本地复制/下载结果 */ }
}

async function cancelDelivery(transfer) {
  if (transfer.source_device !== state.deviceId) return false; // 只能由发送方撤回
  try {
    await api(`/api/v1/deliveries/${encodeURIComponent(transfer.id)}/cancel`, {
      method: 'POST',
      headers: { 'Idempotency-Key': newIdemKey() },
    });
    return true;
  } catch { return false; }
}

async function openTransfer(transfer) {
  if (!transfer || transfer.expired) return;
  const kind = transfer.kind || (transfer.text ? 'text' : 'file');
  if (kind === 'text') {
    await copyTextToClipboard(transfer.text || '');
    toast('文本已复制');
    await ackDelivery(transfer, 'copied');
    refreshAll().catch(() => {});
  } else {
    const link = document.createElement('a');
    link.href = `/api/v1/items/${encodeURIComponent(transfer.item_id)}/content?variant=original`;
    link.download = transfer.name || 'CopySync-download';
    document.body.appendChild(link);
    link.click();
    link.remove();
    toast('正在接收 ' + (transfer.name || '文件'));
    await ackDelivery(transfer, 'downloaded');
    refreshAll().catch(() => {});
  }
}

/* ---------- 发送 / 上传 ---------- */

async function sendText(text, target) {
  await api('/api/v1/items', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': state.idemKey },
    body: JSON.stringify({ kind: 'text', text, target_device: target || undefined }),
  });
}

async function sendFile(file, target) {
  const body = new FormData();
  body.append('file', file);
  if (target) body.append('target_device', target);
  await api('/api/v1/items', { method: 'POST', headers: { 'Idempotency-Key': newIdemKey() }, body });
}

async function sendComposer() {
  if (state.sending) return;
  const btn = $('sendBtn');
  const msg = $('composerMsg');
  const text = $('composerText').value.trim();
  const files = state.pendingFiles;
  if (!text && !files.length) {
    msg.textContent = '请先输入文本或选择文件';
    return;
  }
  const target = $('targetDevice').value || '';
  if (!target) {
    msg.textContent = '暂无目标设备，请先在设备上线后重试';
    return;
  }
  state.sending = true;
  state.idemKey = state.idemKey || newIdemKey(); // 失败重试复用同一幂等键
  btn.disabled = true;
  btn.textContent = '发送中…';
  msg.textContent = '';
  try {
    if (files.length) {
      for (const file of files) await sendFile(file, target);
    } else {
      await sendText(text, target);
    }
    state.idemKey = null;
    state.pendingFiles = [];
    $('composerText').value = '';
    $('composerFiles').textContent = '';
    $('composer').hidden = true;
    $('fileInput').value = '';
    $('imageInput').value = '';
    toast('已加入发送队列');
    await refreshAll();
  } catch (err) {
    msg.textContent = '发送失败：' + err.message + '（可重试，不会产生重复内容）';
  } finally {
    state.sending = false;
    btn.disabled = false;
    btn.textContent = '发送';
  }
}

async function uploadDriveFiles(files) {
  if (!files.length) return;
  const zone = $('dropZone');
  const strong = zone.querySelector('strong');
  const old = strong.textContent;
  zone.classList.add('active');
  strong.textContent = '上传中…';
  const key = newIdemKey();
  try {
    for (const file of files) {
      const body = new FormData();
      body.append('file', file);
      // Idempotency-Key 是 HTTP 头，只能含 ISO-8859-1 字符；文件名可能有中文（如"截屏….png"），
      // 直接拼进头会让 fetch 同步抛 TypeError，被 api() 兜成"网络连接失败"。故对文件名做 encodeURIComponent 转成纯 ASCII。
      await api('/api/v1/items', { method: 'POST', headers: { 'Idempotency-Key': key + ':' + encodeURIComponent(file.name) + ':' + file.size }, body });
    }
    toast(files.length > 1 ? `已上传 ${files.length} 个文件` : '已上传 ' + files[0].name);
    await refreshAll();
  } catch (err) {
    toast('上传失败：' + err.message, true);
  } finally {
    zone.classList.remove('active');
    strong.textContent = old;
    $('driveFiles').value = '';
  }
}

function selectPendingFiles(files) {
  state.pendingFiles = [...files];
  state.idemKey = null;
  $('composer').hidden = false;
  $('composerFiles').textContent = state.pendingFiles.length === 1
    ? '📎 ' + state.pendingFiles[0].name
    : `📎 已选择 ${state.pendingFiles.length} 个文件`;
}

async function pasteFromClipboard() {
  $('composer').hidden = false;
  try {
    const text = await navigator.clipboard.readText();
    if (text) {
      $('composerText').value = text;
      toast('已粘贴，点击发送');
    } else {
      toast('剪贴板里没有文本', true);
    }
  } catch {
    toast('无法读取剪贴板，请手动粘贴（Cmd/Ctrl+V）', true);
  }
  $('composerText').focus();
}

/* ---------- 清理 ---------- */

async function clearTemp(button) {
  if (!confirm('删除全部未固定内容？已固定内容会保留。')) return;
  await withButton(button, '清理中…', async () => {
    try {
      const result = await api('/api/v1/items/clear-temp', {
        method: 'POST',
        headers: { 'Idempotency-Key': newIdemKey() },
      });
      $('clearMsg').textContent = `已删除 ${result.deleted} 项，释放 ${fmtSize(result.bytes)}`;
      await refreshAll();
    } catch (err) {
      $('clearMsg').textContent = '清理失败：' + err.message;
    }
  });
}

/* 彻底清空：删除全部内容（含已固定），二次确认。 */
async function clearAll(button) {
  if (!confirm('彻底清空将删除全部内容（含已固定），不可恢复。继续？')) return;
  if (!confirm('再次确认：真的要清空全部内容吗？')) return;
  await withButton(button, '清空中…', async () => {
    try {
      const result = await api('/api/v1/items/clear-all', {
        method: 'POST',
        headers: { 'Idempotency-Key': newIdemKey() },
      });
      $('clearAllMsg').textContent = `已清空 ${result.deleted} 项，释放 ${fmtSize(result.bytes)}`;
      await refreshAll();
    } catch (err) {
      $('clearAllMsg').textContent = '清空失败：' + err.message;
    }
  });
}

/* 修改密码：成功后全设备 Token 失效，回到登录页。 */
async function changePassword(e) {
  e.preventDefault();
  const btn = $('passwordBtn');
  const msg = $('passwordMsg');
  msg.textContent = '';
  await withButton(btn, '修改中…', async () => {
    try {
      await api('/api/v1/auth/password', {
        method: 'POST',
        body: JSON.stringify({
          current_password: $('currentPassword').value,
          new_password: $('newPassword').value,
        }),
      });
      toast('密码已修改，请用新密码重新登录');
      $('passwordForm').reset();
      showLogin();
    } catch (err) {
      msg.textContent = err.message;
    }
  });
}

/* ---------- 拖拽 ---------- */

function bindDrop(element, onFiles) {
  ['dragenter', 'dragover'].forEach(name => element.addEventListener(name, e => {
    e.preventDefault();
    element.classList.add('active');
  }));
  ['dragleave', 'drop'].forEach(name => element.addEventListener(name, e => {
    e.preventDefault();
    element.classList.remove('active');
  }));
  element.addEventListener('drop', e => {
    // dataTransfer.files 是与 drop 事件绑定的 live FileList，处理器返回后浏览器会清空它。
    // 上传是异步的（await fetch），若直接传引用，真正读文件时它已失效 → fetch 报“网络连接失败”。
    // 这里同步用 Array.from 快照出稳定的 File 引用，picker 走的 input.files 不受影响，行为一致。
    const files = Array.from(e.dataTransfer.files || []);
    if (files.length) onFiles(files);
  });
}

/* ---------- 事件绑定 ---------- */

function bindEvents() {
  $('loginForm').onsubmit = async e => {
    e.preventDefault();
    const btn = $('loginBtn');
    const msg = $('loginMsg');
    if (btn.disabled) return;
    btn.disabled = true;
    btn.textContent = '登录中…';
    msg.textContent = '';
    try {
      await login($('loginPassword').value);
      $('loginPassword').value = '';
      btn.textContent = '登录';
      enterApp();
    } catch (err) {
      msg.textContent = err.message;
    } finally {
      btn.disabled = false;
      btn.textContent = '登录';
    }
  };

  document.querySelectorAll('.nav-item').forEach(b => { b.onclick = () => setView(b.dataset.view); });
  $('refreshBtn').onclick = () => refreshNow($('refreshBtn'));
  $('markAllReadBtn').onclick = markAllRead;
  $('refreshBtn2').onclick = () => refreshNow($('refreshBtn2'));
  $('netRetry').onclick = () => refreshNow($('netRetry'));
  $('logoutBtn').onclick = logout;
  $('clearTempBtn').onclick = () => clearTemp($('clearTempBtn'));
  $('clearAllBtn').onclick = () => clearAll($('clearAllBtn'));
  $('passwordForm').onsubmit = changePassword;
  $('sendBtn').onclick = sendComposer;
  $('pasteBtn').onclick = pasteFromClipboard;
  $('composerText').onkeydown = e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) sendComposer();
  };
  $('fileInput').onchange = () => selectPendingFiles($('fileInput').files);
  $('imageInput').onchange = () => selectPendingFiles($('imageInput').files);
  $('driveFiles').onchange = () => uploadDriveFiles($('driveFiles').files);
  bindDrop($('dropZone'), files => uploadDriveFiles(files));
  $('dropZone').onclick = () => $('driveFiles').click();
  $('searchInput').oninput = renderDrive;
  $('filters').onclick = e => {
    const chip = e.target.closest('.chip');
    if (!chip) return;
    $('filters').querySelectorAll('.chip').forEach(x => x.classList.remove('active'));
    chip.classList.add('active');
    state.filter = chip.dataset.kind;
    renderDrive();
  };

  $('previewClose').onclick = () => { $('previewOverlay').hidden = true; };
  $('previewOverlay').onclick = e => { if (e.target === $('previewOverlay')) $('previewOverlay').hidden = true; };

  document.addEventListener('click', e => {
    if (!e.target.closest('#menu') && !e.target.closest('[data-act="menu"]')) closeMenu();
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') { closeMenu(); $('previewOverlay').hidden = true; }
  });

  // 列表操作（事件委托）
  document.querySelector('.main').addEventListener('click', e => {
    const actBtn = e.target.closest('[data-act]');
    if (actBtn) {
      e.stopPropagation();
      const id = actBtn.dataset.id;
      const item = findItem(id);
      const act = actBtn.dataset.act;
      if (act === 'copy' && item) return withButton(actBtn, '…', () => copyItem(item));
      if (act === 'download' && item) return downloadItem(item);
      if (act === 'menu' && item) return itemMenu(actBtn, item);
      if (act === 'copy-transfer') return withButton(actBtn, '…', () => openTransfer(findDelivery(id)));
      if (act === 'receive-transfer') return openTransfer(findDelivery(id));
      if (act === 'note-save') return saveNote(actBtn, id);
      if (act === 'note-cancel') { actBtn.closest('.note-editor').hidden = true; return; }
      return;
    }
    const editor = e.target.closest('.note-editor');
    if (editor) return;
    const transferRow = e.target.closest('[data-transfer]');
    if (transferRow) {
      if (transferRow.dataset.expired === '1') return;
      const transfer = findDelivery(transferRow.dataset.transfer);
      if (transfer && !transfer.expired) openTransfer(transfer);
      return;
    }
    const itemRow = e.target.closest('[data-item]');
    if (itemRow) {
      const item = findItem(itemRow.dataset.item);
      if (!item) return;
      if (item.kind === 'text') copyItem(item);
      else if (isImage(item)) previewImage(item);
      else downloadItem(item);
    }
  });
}

/* ---------- 启动 ---------- */

async function enterApp() {
  showApp();
  hydrateIcons();
  setView('inbox');
  try {
    await refreshAll();
    setNetBanner('');
  } catch (err) {
    setNetBanner('加载失败：' + err.message);
  }
  connectEvents();
  heartbeat();
}

async function boot() {
  hydrateIcons();
  bindEvents();
  try {
    await api('/api/v1/devices'); // Cookie 仍有效则直接进入主界面
    enterApp();
  } catch {
    showLogin();
  }
}

setInterval(() => { if (!$('appShell').hidden) heartbeat(); }, 60 * 1000);

boot();
