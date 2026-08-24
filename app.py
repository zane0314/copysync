#!/usr/bin/env python3
import base64
import email
import email.policy
import email.utils
import hashlib
import hmac
import html
import io
import json
import mimetypes
import os
import ipaddress
import secrets
import shutil
import sqlite3
import sys
import threading
import time
import urllib.parse
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def load_dotenv(path=".env"):
    env_path = Path(path)
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("'\"")
        os.environ.setdefault(key.strip(), value)


load_dotenv()

DATA_DIR = Path(os.environ.get("WEBCLIP_DATA_DIR", "data"))
FILES_DIR = DATA_DIR / "files"
DB_PATH = DATA_DIR / "clipboard.db"
FAVICON_PATH = Path(os.environ.get("WEBCLIP_FAVICON", "favicon.png"))
UPDATES_DIR = Path(os.environ.get("WEBCLIP_UPDATES_DIR", "updates"))
HOST = os.environ.get("WEBCLIP_HOST", "127.0.0.1")
PORT = int(os.environ.get("WEBCLIP_PORT", "15080"))
USERNAME = os.environ.get("WEBCLIP_USERNAME", "zane")
PASSWORD = os.environ.get("WEBCLIP_PASSWORD", "")
SESSION_SECRET = os.environ.get("WEBCLIP_SESSION_SECRET", "")
PASSWORD_HASH = os.environ.get("WEBCLIP_PASSWORD_HASH", "")
COOKIE_DOMAIN = os.environ.get("WEBCLIP_COOKIE_DOMAIN", "")
COOKIE_SECURE = os.environ.get("WEBCLIP_COOKIE_SECURE", "1") != "0"
DIRECT_URL = os.environ.get("WEBCLIP_DIRECT_URL", "https://copy-direct.example.com")
CF_URL = os.environ.get("WEBCLIP_CF_URL", "https://copy-cf.example.com")
GO_ONLY_HOSTS = {h.strip().lower() for h in os.environ.get("WEBCLIP_GO_ONLY_HOSTS", "copy.example.com").split(",") if h.strip()}
DEFAULT_TTL_SECONDS = int(os.environ.get("WEBCLIP_DEFAULT_TTL_SECONDS", str(4 * 3600)))
DRIVE_TTL_SECONDS = int(os.environ.get("WEBCLIP_DRIVE_TTL_SECONDS", str(7 * 86400)))
TRANSFER_TTL_SECONDS = int(os.environ.get("WEBCLIP_TRANSFER_TTL_SECONDS", str(86400)))
TRANSFER_HISTORY_TTL_SECONDS = int(os.environ.get("WEBCLIP_TRANSFER_HISTORY_TTL_SECONDS", str(30 * 86400)))
MAX_FILE_BYTES = int(os.environ.get("WEBCLIP_MAX_FILE_BYTES", str(100 * 1024 * 1024)))
MAX_UPLOAD_BYTES = int(os.environ.get("WEBCLIP_MAX_UPLOAD_BYTES", str(110 * 1024 * 1024)))
PINNED_LIMIT_BYTES = int(os.environ.get("WEBCLIP_PINNED_LIMIT_BYTES", str(5 * 1024 * 1024 * 1024)))
TEMP_LIMIT_BYTES = int(os.environ.get("WEBCLIP_TEMP_LIMIT_BYTES", str(2 * 1024 * 1024 * 1024)))
DISK_HIGH_WATER = float(os.environ.get("WEBCLIP_DISK_HIGH_WATER", "0.80"))
ITEM_EVENTS = threading.Condition()
ITEMS_VERSION = 0
SYNC_KEEP = 10000
CONNECT_SOURCES = " ".join(
    dict.fromkeys(
        [
            "'self'",
            *(
                f"{url.scheme}://{url.netloc}"
                for url in map(urllib.parse.urlparse, (DIRECT_URL, CF_URL))
                if url.scheme in {"http", "https"} and url.netloc
            ),
        ]
    )
)
CSP = (
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
    f"script-src 'self' 'unsafe-inline'; connect-src {CONNECT_SOURCES}; "
    "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)


INDEX_HTML = """<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CopySync</title>
  <link rel="icon" type="image/png" href="/favicon.png">
  <style>
    :root { color-scheme: light; font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --green:#0b5c3e; --green-dark:#074a32; --green-press:#063f2b; --sage:#eef6f0; --line:#eee9e2; --muted:#69716c; --bg:#faf9f7; --card-shadow:0 6px 18px rgba(60,50,35,.04); }
    * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
    button:focus, .act:focus, .pin:focus { outline:none; }
    button:focus-visible, .act:focus-visible { outline:2px solid rgba(11,92,62,.4); outline-offset:2px; }
    body { margin:0; background:var(--bg); color:#171c19; }
    button,input,textarea,select { font:inherit; }
    button,.button { border:0; border-radius:9px; padding:11px 18px; cursor:pointer; font-weight:650; background:var(--green); color:#fff; text-decoration:none; transition:all .15s ease; }
    button:hover:not(:disabled), .button:hover { background:var(--green-dark); transform:translateY(-1px); box-shadow:0 4px 12px rgba(11,92,62,.28); }
    button:active:not(:disabled), .button:active { background:var(--green-press); transform:translateY(1px); box-shadow:inset 0 2px 4px rgba(0,0,0,.2); }
    button.secondary,.button.secondary { background:#fff; color:var(--green); border:1px solid #a9b9af; }
    button.secondary:hover:not(:disabled), .button.secondary:hover { background:#f0f7f2; box-shadow:0 4px 12px rgba(11,92,62,.12); }
    button.ghost { background:transparent; color:#4e5752; padding:7px 9px; font-weight:400; }
    button.ghost:hover:not(:disabled) { background:#f0f4f1; color:var(--green); box-shadow:none; }
    button:disabled { opacity:.55; cursor:not-allowed; }
    .hidden,[hidden] { display:none!important; }
    .muted { color:var(--muted); font-size:14px; }
    .dot { width:9px; height:9px; border-radius:50%; background:#17a15d; display:inline-block; flex:0 0 auto; }
    .dot.offline { background:#c7cbc8; border:1px solid #888; }
    .header { height:74px; border-bottom:1px solid var(--line); background:rgba(255,255,255,.85); backdrop-filter:blur(18px); position:sticky; top:0; z-index:10; }
    .nav { max-width:1480px; height:100%; margin:auto; padding:0 28px; display:flex; align-items:center; gap:34px; }
    .brand { font-size:34px; font-weight:800; color:var(--green); letter-spacing:-1px; }
    .health { display:flex; align-items:center; gap:9px; color:#56605a; }
    .user { display:flex; align-items:center; gap:10px; margin-left:auto; }
    .avatar { width:38px; height:38px; border-radius:50%; display:grid; place-items:center; background:#d8eee0; color:var(--green); font-weight:800; }
    main { max-width:1480px; margin:0 auto; padding:20px 28px 48px; }
    .workspace { display:grid; grid-template-columns:minmax(0,2.35fr) minmax(320px,1fr); gap:20px; align-items:start; }
    .panel { background:#fff; border:1px solid var(--line); border-radius:14px; box-shadow:var(--card-shadow); }
    .drive { padding:22px 20px; min-width:0; }
    .drive-head { display:flex; align-items:center; gap:10px; }
    .capacity-line { margin:8px 0 2px; font-size:13px; }
    h1,h2 { margin:0; color:#162019; }
    h1 { font-size:23px; }
    h2 { font-size:19px; }
    .drop-hint { flex:1; border:1.5px dashed #c9d8ce; border-radius:10px; padding:10px 14px; color:#7c8a80; background:#fbfdfc; transition:all .15s ease; }
    .drop-hint.active,.transfer-drop.active { outline:2px solid var(--green); background:var(--sage); }
    .search { width:100%; margin:14px 0; border:1px solid var(--line); border-radius:9px; padding:13px 15px; background:#fff; outline:none; transition:border-color .15s ease, box-shadow .15s ease; }
    .search:focus { border-color:#bcd4c6; box-shadow:0 0 0 3px rgba(11,92,62,.08); }
    .filters { display:flex; gap:10px; margin-bottom:14px; overflow:auto; }
    .chip { background:#fff; color:#5a625d; border:1px solid var(--line); border-radius:999px; min-width:74px; padding:8px 16px; font-weight:400; transition:all .15s ease; }
    .chip:hover:not(.active):not(:disabled) { color:var(--green); border-color:#cfdcd3; background:#fff; transform:translateY(-1px); box-shadow:0 3px 8px rgba(60,50,35,.06); }
    .chip.active { background:var(--green); color:#fff; border-color:var(--green); }
    .file-list { border:1px solid #f0ebe3; border-radius:12px; overflow:hidden; background:#fff; }
    .file-row { display:grid; grid-template-columns:26px minmax(0,1fr) auto; align-items:center; gap:12px; min-height:84px; padding:12px 14px; border-bottom:1px solid #f3efe8; }
    .file-row:last-child { border-bottom:0; }
    .pin { width:26px; height:34px; border:0; background:none; font-size:15px; cursor:pointer; display:grid; place-items:center; padding:0; transition:transform .35s cubic-bezier(.34,1.45,.64,1), opacity .2s ease, filter .2s ease; }
    .pin.off { transform:rotate(-45deg); filter:grayscale(1); opacity:.45; }
    .pin.off:hover { opacity:.85; transform:rotate(-45deg) scale(1.12); }
    .pin.on { color:var(--green); }
    .pin.on:hover { transform:scale(1.12); }
    .file-main { display:flex; align-items:center; gap:14px; min-width:0; }
    .file-icon { width:52px; height:52px; border-radius:9px; display:grid; place-items:center; background:var(--sage); color:var(--green); font-size:23px; flex:0 0 auto; overflow:hidden; }
    .file-icon img { width:100%; height:100%; object-fit:cover; }
    .file-copy { min-width:0; }
    .file-name { font-size:16px; white-space:nowrap; text-overflow:ellipsis; overflow:hidden; margin-bottom:5px; }
    .file-preview { white-space:nowrap; text-overflow:ellipsis; overflow:hidden; color:#39433d; margin-bottom:4px; }
    .row-actions { display:flex; align-items:center; gap:3px; white-space:nowrap; }
    .row-actions .act { -webkit-appearance:none; appearance:none; background:none; border:0; font-family:inherit; font-size:13px; font-weight:400; line-height:1.2; color:#5c665f; padding:6px 8px; border-radius:6px; cursor:pointer; text-decoration:none; transition:all .15s ease; display:inline-flex; align-items:center; justify-content:center; min-height:30px; box-sizing:border-box; }
    .row-actions .act:hover { color:var(--green); background:#f0f7f2; transform:translateY(-1px); box-shadow:none; }
    .row-actions .act:active { transform:translateY(1px); }
    .empty { text-align:center; padding:45px 12px; color:var(--muted); }
    .transfer { position:sticky; top:94px; padding:20px; }
    .field-label { display:block; margin:18px 0 8px; color:#58615c; font-size:13px; font-weight:700; }
    select,.transfer textarea { width:100%; border:1px solid var(--line); border-radius:9px; background:#fff; color:#202923; outline:none; }
    select { padding:12px; }
    .transfer-drop { margin-top:14px; border:1px dashed #cbd2cd; border-radius:11px; padding:16px; text-align:center; background:#fdfdfc; }
    .transfer textarea { min-height:84px; resize:vertical; border:0; padding:10px; background:transparent; }
    .type-actions { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; margin-top:8px; }
    .type-actions label { border:1px solid var(--line); border-radius:8px; padding:9px 4px; cursor:pointer; background:#fff; }
    .selected-file { margin:12px 0; padding:10px; border:1px solid var(--line); border-radius:9px; display:flex; align-items:center; gap:8px; overflow:hidden; }
    .selected-file span { min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .checkline { display:flex; align-items:center; gap:9px; margin:13px 0; }
    .checkline input { width:18px; height:18px; accent-color:var(--green); }
    .send-button { width:100%; margin-top:12px; font-size:16px; }
    .transfer-msg { min-height:22px; margin:9px 0 0; }
    .ttl-note { font-size:12px; color:#a3a79f; margin:6px 0 0 2px; }
    .recent { border-top:1px solid var(--line); margin-top:18px; padding-top:17px; }
    .recent h2 { font-size:16px; margin-bottom:10px; }
    .myfiles-box { border:1px solid #f0ebe3; border-radius:10px; overflow:hidden; }
    .myfile-row { display:flex; align-items:center; gap:10px; padding:10px 11px; border-bottom:1px solid #f3efe8; }
    .myfile-row:last-child { border-bottom:0; }
    .mthumb { width:30px; height:30px; border-radius:8px; background:var(--sage); color:var(--green); display:grid; place-items:center; font-size:14px; overflow:hidden; flex:0 0 auto; }
    .mthumb img { width:100%; height:100%; object-fit:cover; }
    .myfile-copy { min-width:0; flex:1; }
    .myfile-copy .file-name { font-size:13px; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; margin-bottom:2px; }
    .myfiles-box > p.muted { padding:12px; margin:0; }
    .status.expired { color:#9aa099; font-weight:400; }
    .transfer-row.expired > div { color:#9aa099; }
    .transfer-row { display:grid; grid-template-columns:1fr auto; gap:10px; padding:10px 0; border-bottom:1px solid #ecebe7; }
    .transfer-row { position:relative; overflow:hidden; touch-action:pan-y; }
    .transfer-row .swipe-link { position:absolute; left:10px; top:50%; transform:translate(-115%,-50%); opacity:0; pointer-events:none; border:0; border-radius:10px; padding:9px 11px; color:#fff; background:var(--green); font-weight:750; transition:.18s ease; }
    .transfer-row.swiped .swipe-link { transform:translate(0,-50%); opacity:1; pointer-events:auto; }
    .transfer-row .android-transfer-main,.transfer-row .android-status,.transfer-row .mac-transfer-main,.transfer-row .mac-status-wrap { transition:transform .18s ease; }
    .transfer-row.swiped .android-transfer-main,.transfer-row.swiped .android-status,.transfer-row.swiped .mac-transfer-main,.transfer-row.swiped .mac-status-wrap { transform:translateX(128px); }
    .glass-toast { position:fixed; z-index:1000; left:50%; bottom:78px; max-width:min(86vw,520px); transform:translate(-50%,18px); padding:10px 16px; border:1px solid rgba(255,255,255,.34); border-radius:14px; color:#fff; background:rgba(28,34,31,.72); box-shadow:0 10px 34px rgba(0,0,0,.22); backdrop-filter:blur(18px) saturate(145%); -webkit-backdrop-filter:blur(18px) saturate(145%); opacity:0; pointer-events:none; transition:opacity .2s ease,transform .2s ease; text-align:center; }
    .glass-toast.show { opacity:1; transform:translate(-50%,0); }
    .status { color:var(--green); font-size:13px; font-weight:750; }
    .status.waiting { color:#c68312; }
    .login-panel,.go-panel { max-width:480px; margin:54px auto; padding:28px; background:#fff; border:1px solid var(--line); border-radius:14px; box-shadow:var(--card-shadow); }
    .login-panel h1,.go-panel h1 { margin-bottom:20px; }
    .login-panel input { width:100%; border:1px solid var(--line); border-radius:8px; padding:12px; margin-bottom:12px; }
    .login-panel button { width:100%; }
    .go-panel article { border:1px solid var(--line); border-radius:10px; padding:14px; margin:10px 0; }
    .top { display:flex; align-items:center; justify-content:space-between; gap:15px; }
    body.android-app { background:var(--bg); }
    body.android-app .header { display:none; }
    body.android-app main { max-width:620px; padding:25px 18px 30px; }
    .android-home,.android-inbox,.android-drive { color:#151b18; }
    .android-brand { color:var(--green); font-size:38px; font-weight:820; letter-spacing:-1.3px; margin:2px 0 5px; }
    .android-online { display:flex; align-items:center; gap:10px; font-size:16px; margin-bottom:20px; color:#5c665f; }
    .android-target { display:grid; grid-template-columns:54px minmax(0,1fr); align-items:center; gap:10px; border:1px solid var(--line); border-radius:14px; padding:10px 12px; min-height:74px; background:#fff; box-shadow:var(--card-shadow); }
    .android-target-icon { width:48px; height:48px; border-radius:12px; display:grid; place-items:center; color:var(--green); background:var(--sage); font-size:27px; }
    .android-target-icon svg { width:30px; height:30px; }
    .android-target select { border:0; padding:8px 4px; font-size:17px; font-weight:600; background:#fff; }
    .android-quick { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:10px; margin:16px 0 22px; }
    .android-action { min-width:0; height:120px; border:1px solid var(--line); border-radius:14px; display:flex; flex-direction:column; justify-content:center; align-items:center; gap:12px; background:#fff; color:#17221b; padding:8px 4px; font-weight:650; cursor:pointer; text-align:center; box-shadow:var(--card-shadow); transition:all .15s ease; }
    button.android-action { color:#17221b; font-weight:650; }
    .android-action:active { transform:translateY(1px) scale(.98); background:#f0f7f2; box-shadow:none; }
    .android-action-icon { color:var(--green); font-size:34px; line-height:1; }
    .android-action-icon svg { width:36px; height:36px; }
    .android-composer { border:1px dashed #ddd5c9; border-radius:10px; padding:10px; margin:-6px 0 12px; background:#fcfbf9; }
    .android-composer textarea { width:100%; min-height:92px; border:0; resize:vertical; background:transparent; padding:8px; outline:none; }
    .android-send-options { border:1px solid var(--line); border-radius:14px; padding:12px; margin-bottom:18px; background:#fff; box-shadow:var(--card-shadow); }
    .android-section-title { font-size:20px; margin:0 0 10px; }
    .android-recents { display:grid; gap:10px; }
    .android-recents .transfer-row { min-height:72px; border:1px solid var(--line); border-radius:14px; padding:11px 12px; align-items:center; background:#fff; box-shadow:var(--card-shadow); border-bottom:1px solid var(--line); }
    .android-recents .transfer-row[data-receive] { cursor:pointer; }
    .android-recents .transfer-row[data-receive]:active { background:#f0f7f2; }
    .android-recents .transfer-row:last-child { border-bottom:1px solid var(--line); }
    .android-transfer-main { display:grid; grid-template-columns:48px minmax(0,1fr); gap:11px; align-items:center; }
    .android-transfer-icon { width:44px; height:44px; border-radius:11px; display:grid; place-items:center; background:var(--sage); color:var(--green); font-size:22px; overflow:hidden; }
    .android-transfer-icon svg { width:24px; height:24px; }
    .android-transfer-icon img { width:100%; height:100%; object-fit:cover; }
    .android-status { display:flex; align-items:center; gap:8px; flex:0 0 auto; }
    .android-status .status { white-space:nowrap; }
    .android-recents .status { white-space:nowrap; }
    .android-recents .transfer-row strong { display:block; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .android-recents .transfer-row > div { min-width:0; }
    .android-transfer-main strong { display:block; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .android-status .act { background:none; border:0; font-size:13px; color:#5c665f; padding:8px 9px; border-radius:6px; cursor:pointer; text-decoration:none; transition:all .15s ease; }
    .android-status .act:active { color:var(--green); background:#eef6f0; transform:translateY(1px); }
    .android-inbox,.android-drive { padding-top:8px; }
    .android-inbox .myfiles-box,.android-drive .file-list { margin-top:12px; }
    .android-inbox-head,.android-drive-head { display:flex; align-items:center; justify-content:space-between; gap:10px; margin-bottom:10px; }
    .android-drive .drive-head { margin-top:10px; display:flex; align-items:center; gap:10px; }
    body.android-app .drop-hint { display:flex; align-items:center; flex:1; }
    body.android-app .drive-head .button { width:auto; flex:0 0 auto; }
    .android-inbox .myfiles-box .transfer-row { padding:11px 12px; align-items:center; }
    .android-inbox .myfiles-box .transfer-row:last-child { border-bottom:0; }
    .android-inbox .myfiles-box > p.muted { padding:12px; margin:0; }
    .android-page-title { font-size:26px; font-weight:800; color:var(--green); letter-spacing:-.8px; margin:2px 0 4px; }
    body.mac-app { min-height:100vh; background:var(--bg); color:#22271f; }
    body.mac-app .header { display:none; }
    body.mac-app main { max-width:none; min-height:100vh; padding:26px 28px 34px; }
    .mac-home { min-height:calc(100vh - 60px); }
    .mac-title-row { display:flex; justify-content:space-between; align-items:flex-start; gap:20px; margin-bottom:20px; }
    .mac-title-row h1 { color:#162019; font-size:24px; margin-bottom:6px; }
    .mac-refresh-btn { flex:0 0 auto; margin-top:4px; }
    .mac-online { display:flex; align-items:center; gap:9px; color:#5c665f; font-size:13px; }
    .mac-upload { display:flex; align-items:center; gap:10px; margin-bottom:16px; }
    body.mac-app .drop-hint { display:flex; align-items:center; flex:1; }
    body.mac-app .mac-upload .button { width:auto; flex:0 0 auto; }
    .mac-sendbar { display:grid; grid-template-columns:minmax(210px,1.4fr) repeat(3,minmax(112px,1fr)); gap:10px; margin-bottom:20px; }
    .mac-sendbar select,.mac-action { min-height:48px; border:1px solid var(--line); border-radius:11px; background:#fff; color:#3c453f; font-size:14px; box-shadow:var(--card-shadow); transition:all .15s ease; }
    .mac-sendbar select { padding:0 14px; }
    .mac-action { display:flex; align-items:center; justify-content:center; gap:8px; padding:0 12px; cursor:pointer; font-weight:600; text-align:center; }
    button.mac-action { color:#3c453f; }
    .mac-action svg { width:18px; height:18px; color:var(--green); }
    .mac-action:active { transform:translateY(1px); background:#f0f7f2; box-shadow:none; }
    .mac-section-title { color:#162019; font-size:17px; margin:16px 0 10px; }
    .mac-myfiles .myfile-row[data-receive] { cursor:pointer; }
    .mac-file-msg { min-height:22px; margin:-10px 0 14px; }
    @media (max-width:900px) {
      .nav { padding:0 14px; gap:14px; }
      .health { display:none; }
      .user { margin-left:auto; }
      main { padding:12px 12px 32px; }
      .workspace { grid-template-columns:1fr; }
      .transfer { position:static; order:-1; }
      .drive { padding:16px 12px; }
      .drop-hint { display:none; }
      .file-row { grid-template-columns:26px minmax(0,1fr); min-height:92px; }
      .row-actions { grid-column:2; justify-content:flex-start; margin-top:2px; flex-wrap:wrap; }
      .row-actions .act { min-height:40px; }
      .file-icon { width:46px; height:46px; }
    }
    @media (max-width:520px) {
      .header { height:62px; padding-top:env(safe-area-inset-top); }
      .brand { font-size:27px; }
      .avatar { width:34px; height:34px; }
      .transfer,.drive { border-radius:12px; }
      .drive-head .button { width:100%; text-align:center; }
      .search { margin:12px 0; }
      .file-row { padding:11px 9px; gap:8px; }
      .file-main { gap:9px; }
      .row-actions .desktop-only { display:none; }
      body.android-app main { padding:22px 16px 24px; }
      .android-brand { font-size:35px; }
      .android-action { height:132px; }
      .android-action-icon { font-size:36px; }
    }
  </style>
</head>
<body><header class="header"><nav class="nav"><div class="brand">CopySync</div><div class="health"><span class="dot"></span><span id="webOnlineCount">设备连接中</span></div><div class="user" id="userStatus"><div class="avatar">Z</div><span>已登录</span></div></nav></header><main id="app"></main>
<script>
const FORCE_GO = __FORCE_GO__;
const IS_ANDROID_APP = new URLSearchParams(location.search).get('app') === 'android';
const IS_MAC_APP = new URLSearchParams(location.search).get('app') === 'mac';
const CURRENT_DEVICE = IS_ANDROID_APP ? 'android' : IS_MAC_APP ? 'mac' : 'web';
const app = document.querySelector('#app');
const userStatus = document.querySelector('#userStatus');
const api = (path, opts={}) => fetch(path, opts).then(async r => {
  if (r.status === 401) throw new Error('unauthorized');
  const text = await r.text();
  const data = text ? JSON.parse(text) : {};
  if (!r.ok) throw new Error(data.error || r.statusText);
  return data;
});
const fmtSize = n => n < 1024 ? n + ' B' : n < 1048576 ? (n/1024).toFixed(1) + ' KB' : (n/1048576).toFixed(1) + ' MB';
const fmtTime = ts => ts ? new Date(ts * 1000).toLocaleString() : '永久';
const fmtExpire = ts => ts ? '过期 ' + new Date(ts * 1000).toLocaleDateString() : '临时内容';
const fmtRemain = ts => { if (!ts) return '永久'; const s = ts - Date.now() / 1000; if (s <= 0) return '已到期'; if (s < 3600) return `剩 ${Math.max(1, Math.round(s / 60))} 分钟`; if (s < 86400) return `剩 ${Math.round(s / 3600)} 小时`; return `剩 ${Math.round(s / 86400)} 天`; };
let allItems = [];
let itemsFingerprint = '';
let itemEvents;
let latestTransfers = [];
let androidInboxShown = [];
let deviceNames = {web:'网页', mac:'Mac', android:'Android', all:'全部设备'};
async function route() {
  document.body.classList.toggle('android-app', IS_ANDROID_APP);
  document.body.classList.toggle('mac-app', IS_MAC_APP);
  if (FORCE_GO || location.pathname === '/go') return renderGo();
  try { await api('/api/me'); renderApp(); } catch { renderLogin(); }
}
function renderLogin() {
  userStatus.hidden = true;
  app.innerHTML = `<section class="login-panel"><h1>登录</h1><form id="login"><div class="field"><input name="username" autocomplete="username" placeholder="用户名"></div><div class="field"><input name="password" type="password" autocomplete="current-password" placeholder="密码"></div><button>登录</button><p class="muted" id="err"></p></form></section>`;
  login.onsubmit = async e => {
    e.preventDefault();
    try { await api('/api/login', {method:'POST', body:new FormData(login)}); window.CopySyncNative?.loginSucceeded?.(); renderApp(); }
    catch (err) { document.querySelector('#err').textContent = err.message; }
  };
}
function renderGo() {
  userStatus.hidden = true;
  app.innerHTML = `<section class="go-panel"><h1>选择入口</h1><div class="items" id="links"></div><p class="muted" id="hint">检测使用 HTTPS 请求，每条线路最多测 3 次，手动选择入口。</p></section>`;
  const targets = [{id:'direct', name:'直连 VPS', url:'__DIRECT_URL__'}, {id:'cf', name:'Cloudflare', url:'__CF_URL__'}];
  links.innerHTML = targets.map(t => `<article><div class="top"><div><strong>${t.name}</strong><div class="muted">${t.url}</div></div><a class="button" href="${t.url}">打开</a></div><p class="muted" id="${t.id}">检测中</p></article>`).join('');
  Promise.all(targets.map(testLine)).then(results => {
    const usable = results.filter(r => r.ms);
    if (usable.length) {
      usable.sort((a, b) => a.ms - b.ms);
      hint.textContent = `正在进入延迟最低的 ${usable[0].name}（约 ${usable[0].ms} ms）…`;
      location.replace(usable[0].url);
    } else {
      hint.textContent = '两条线路当前都未检测成功。';
    }
  });
}
async function testLine(t) {
  const values = [];
  for (let i = 0; i < 3; i++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2000);
    const start = performance.now();
    try {
      const r = await fetch(t.url + '/probe?ts=' + Date.now(), {cache:'no-store', signal:controller.signal});
      if (r.ok) values.push(Math.round(performance.now() - start));
    } catch {}
    clearTimeout(timeout);
  }
  const el = document.getElementById(t.id);
  if (!values.length) {
    el.textContent = '不可用或超时';
    return {...t, ms: 0};
  }
  values.sort((a, b) => a - b);
  const ms = values[Math.floor(values.length / 2)];
  el.textContent = `约 ${ms} ms，${values.length}/3 次成功`;
  return {...t, ms};
}
async function renderApp() {
  userStatus.hidden = false;
  document.body.classList.toggle('android-app', IS_ANDROID_APP);
  document.body.classList.toggle('mac-app', IS_MAC_APP);
  app.innerHTML = IS_ANDROID_APP ? androidAppHtml() : IS_MAC_APP ? macAppHtml() : `<div class="workspace">
    <section class="panel drive">
      <div class="drive-head"><span class="drop-hint" id="dropZone">⬇ 拖文件到这里上传</span><label class="button" for="driveFiles">上传</label><input class="hidden" id="driveFiles" type="file" multiple></div>
      <div class="muted capacity-line"><span id="capacity">正在计算空间…</span> · 默认保存 7 天</div>
      <input class="search" id="searchInput" placeholder="搜索文本、文件和图片">
      <div class="filters" id="filters"><button class="chip active" data-kind="">全部</button><button class="chip" data-kind="text">文本</button><button class="chip" data-kind="file">文件</button><button class="chip" data-kind="image">图片</button><button class="chip" data-kind="pinned">已固定</button></div>
      <div class="file-list" id="items"><div class="empty">正在载入…</div></div>
      <div class="top" style="margin-top:14px"><span class="muted" id="clearMsg"></span><div><button class="ghost" id="refreshBtn">刷新</button><button class="ghost" id="clearAll">清理临时内容</button></div></div>
    </section>
    <aside class="panel transfer" id="transferPanel">
      <h2>设备传输</h2>
      <label class="field-label" for="targetDevice">目标设备</label><select id="targetDevice"></select>
      <div class="transfer-drop" id="transferDrop"><textarea id="smartInput" placeholder="粘贴文本，或拖入文件和图片"></textarea><div class="type-actions"><label for="transferFiles">📄 文件</label><label for="transferImages">🖼 图片</label><button class="ghost" id="pasteText">📋 粘贴</button></div><input class="hidden" id="transferFiles" type="file" multiple><input class="hidden" id="transferImages" type="file" accept="image/*" multiple></div>
      <div class="selected-file hidden" id="selectedFile">📎 <span></span></div>
      <input class="hidden" id="syncWeb" type="checkbox" checked aria-hidden="true" tabindex="-1">
      <label class="field-label" for="transferTtl">保留时间</label><select id="transferTtl"><option value="14400">4 小时</option><option value="86400" selected>1 天</option><option value="259200">3 天</option><option value="604800">7 天</option></select>
      <div class="ttl-note">默认 1 天，到期自动删除；网页自动保留记录</div>
      <button class="send-button" id="uploadBtn">发送</button><p class="muted transfer-msg" id="fileMsg"></p>
      <div class="recent"><h2>我的文件</h2><div class="myfiles-box" id="myFiles"><p class="muted">暂无内容</p></div></div>
      <div class="recent"><h2>传输记录</h2><div id="transferRecords"><p class="muted">暂无记录</p></div></div>
    </aside>
  </div>`;
  uploadBtn.onclick = sendTransfer;
  const newTextButton = document.getElementById('newText');
  if (newTextButton) newTextButton.onclick = () => { smartInput.focus(); transferPanel.scrollIntoView({behavior:'smooth', block:'start'}); };
  smartInput.onkeydown = e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) sendTransfer(); };
  smartInput.oninput = () => { if (IS_ANDROID_APP) document.getElementById('androidSendOptions').classList.toggle('hidden', !smartInput.value.trim()); };
  clearAll.onclick = async () => confirm('删除全部未固定内容？已固定内容会保留。') && clearItems('/api/clear-temp');
  refreshBtn.onclick = () => refreshNow();
  const macRefreshBtn = document.getElementById('macRefreshBtn');
  if (macRefreshBtn) macRefreshBtn.onclick = () => refreshNow(macRefreshBtn);
  driveFiles.onchange = () => uploadDriveFiles(driveFiles.files);
  transferFiles.onchange = async () => { selectTransferFiles(transferFiles.files); if (IS_MAC_APP) await sendTransfer(); };
  transferImages.onchange = async () => { selectTransferFiles(transferImages.files); if (IS_MAC_APP) await sendTransfer(); };
  pasteText.onclick = async () => { if (IS_ANDROID_APP) showAndroidSection('send'); try { const text = (IS_MAC_APP && window.webkit?.messageHandlers?.copySync) ? await readMacClipboard() : await navigator.clipboard.readText(); smartInput.value = text; smartInput.dispatchEvent(new Event('input')); if (IS_MAC_APP) await sendTransfer(); else smartInput.focus(); } catch { fileMsg.textContent = IS_MAC_APP ? '剪贴板里没有文本' : '请长按输入框粘贴文本'; smartInput.focus(); } };
  searchInput.oninput = renderItems;
  filters.onclick = e => { const chip = e.target.closest('.chip'); if (!chip) return; filters.querySelectorAll('.chip').forEach(x => x.classList.remove('active')); chip.classList.add('active'); renderItems(); };
  bindDrop(dropZone, files => uploadDriveFiles(files));
  bindDrop(IS_MAC_APP ? macInbox : transferDrop, async files => {
    selectTransferFiles(files);
    if (IS_MAC_APP) await sendTransfer();
  });
  itemsFingerprint = '';
  await Promise.all([loadItems(true), loadDevices(), loadTransfers(), loadUsage()]);
  itemEvents?.close();
  itemEvents = new EventSource('/api/events');
  itemEvents.addEventListener('items', () => Promise.all([loadItems(), loadTransfers(), loadDevices(), loadUsage()]));
}
function macAppHtml() {
  return `<section class="mac-home" id="macInbox">
    <div class="mac-title-row"><div><h1>收件箱</h1><div class="mac-online"><span class="dot"></span><span id="macOnlineCount">设备连接中</span></div></div><button class="ghost mac-refresh-btn" id="macRefreshBtn" title="刷新收件箱">刷新</button></div>
    <div class="mac-upload"><span class="drop-hint" id="dropZone">⬇ 拖文件到这里上传</span><label class="button" for="driveFiles">上传</label></div>
    <div class="mac-sendbar"><select id="targetDevice" aria-label="发送目标"></select><button class="mac-action" id="pasteText">${androidIcon('text')}粘贴文本</button><label class="mac-action" for="transferFiles">${androidIcon('file')}选文件</label><label class="mac-action" for="transferImages">${androidIcon('image')}选照片</label></div>
    <p class="muted mac-file-msg" id="fileMsg"></p>
    <h2 class="mac-section-title">我的文件</h2><div class="mac-myfiles myfiles-box" id="macMyFiles"><p class="muted">暂无内容</p></div>
    <div class="hidden" id="transferDrop"><textarea id="smartInput"></textarea></div><div class="selected-file hidden" id="selectedFile">📎 <span></span></div><input class="hidden" id="syncWeb" type="checkbox" checked aria-hidden="true" tabindex="-1"><select class="hidden" id="transferTtl"><option value="86400" selected>1 天</option></select><button class="hidden" id="uploadBtn">发送</button>
    <input class="hidden" id="transferFiles" type="file" multiple><input class="hidden" id="transferImages" type="file" accept="image/*" multiple><input class="hidden" id="driveFiles" type="file" multiple>
  </section>
  <section class="mac-home hidden" id="macRecords"><div class="mac-title-row"><div><h1>传输历史</h1><div class="mac-online">完整记录 · 保留 30 天</div></div></div><div class="myfiles-box" id="macRecordsList"><p class="muted">暂无记录</p></div></section>
  <section class="mac-home hidden" id="macDrive"><div class="mac-title-row"><div><h1>临时网盘</h1><div class="mac-online"><span id="capacity">正在计算空间…</span> · 默认保存 7 天</div></div></div><input class="search" id="searchInput" placeholder="搜索文本、文件和图片"><div class="filters" id="filters"><button class="chip active" data-kind="">全部</button><button class="chip" data-kind="text">文本</button><button class="chip" data-kind="file">文件</button><button class="chip" data-kind="image">图片</button><button class="chip" data-kind="pinned">已固定</button></div><div class="file-list" id="items"><div class="empty">正在载入…</div></div><div class="top" style="margin-top:12px"><span class="muted" id="clearMsg"></span><div><button class="ghost" id="refreshBtn">刷新</button><button class="ghost" id="clearAll">清理临时内容</button></div></div></section>`;
}
function showMacSection(section) {
  if (!IS_MAC_APP) return;
  macInbox.classList.toggle('hidden', section !== 'inbox');
  macRecords.classList.toggle('hidden', section !== 'records');
  macDrive.classList.toggle('hidden', section !== 'drive');
  scrollTo({top:0});
}
window.showMacSection = showMacSection;
function androidIcon(kind) {
  const paths = {
    laptop:'<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
    text:'<path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/>',
    file:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
    image:'<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.5-3.5a2 2 0 0 0-3 0L6 20"/>',
    note:'<path d="M4 17l6-6-6-6M12 19h8"/>'
  };
  return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${paths[kind]}</svg>`;
}
function androidAppHtml() {
  return `<section class="android-home" id="androidHome">
    <div class="android-brand">CopySync</div><div class="android-online"><span class="dot"></span><span id="onlineCount">设备连接中</span></div>
    <div class="android-target"><div class="android-target-icon">${androidIcon('laptop')}</div><select id="targetDevice" aria-label="发送目标"></select></div>
    <div class="android-quick"><button class="android-action" id="pasteText"><span class="android-action-icon">${androidIcon('text')}</span><span>粘贴文本</span></button><label class="android-action" for="transferFiles"><span class="android-action-icon">${androidIcon('file')}</span><span>选文件</span></label><label class="android-action" for="transferImages"><span class="android-action-icon">${androidIcon('image')}</span><span>选照片</span></label></div>
    <div class="android-composer hidden" id="transferDrop"><textarea id="smartInput" placeholder="输入或长按粘贴文本"></textarea></div>
    <div class="android-send-options hidden" id="androidSendOptions"><div class="selected-file hidden" id="selectedFile">📎 <span></span></div><input class="hidden" id="syncWeb" type="checkbox" checked aria-hidden="true" tabindex="-1"><select id="transferTtl" aria-label="保留时间"><option value="14400">保留 4 小时</option><option value="86400" selected>保留 1 天</option><option value="259200">保留 3 天</option><option value="604800">保留 7 天</option></select><div class="ttl-note">默认 1 天，到期自动删除；网页自动保留记录</div><button class="send-button" id="uploadBtn">发送</button><p class="muted transfer-msg" id="fileMsg"></p></div>
    <input class="hidden" id="transferFiles" type="file" multiple><input class="hidden" id="transferImages" type="file" accept="image/*" multiple>
    <h2 class="android-section-title">传输记录</h2><div class="android-recents" id="androidRecords"><p class="muted">暂无记录</p></div>
  </section>
  <section class="android-inbox hidden" id="androidInbox"><div class="android-page-title">收件箱</div><div class="muted">收到的内容 · 到期自动消失</div><div class="myfiles-box" id="androidInboxList"><p class="muted">暂无内容</p></div><h2 class="android-section-title" style="margin-top:18px">传输记录</h2><div class="android-recents" id="androidInboxRecords"><p class="muted">暂无记录</p></div></section>
  <section class="android-drive hidden" id="androidDrive"><div class="android-page-title">网盘</div><div class="muted"><span id="capacity">正在计算空间…</span> · 默认保存 7 天</div><div class="drive-head"><span class="drop-hint" id="dropZone">⬇ 拖文件到这里上传</span><label class="button" for="driveFiles">上传</label><input class="hidden" id="driveFiles" type="file" multiple></div><input class="search" id="searchInput" placeholder="搜索文本、文件和图片"><div class="filters" id="filters"><button class="chip active" data-kind="">全部</button><button class="chip" data-kind="text">文本</button><button class="chip" data-kind="file">文件</button><button class="chip" data-kind="image">图片</button><button class="chip" data-kind="pinned">已固定</button></div><div class="file-list" id="items"><div class="empty">正在载入…</div></div><div class="top" style="margin-top:12px"><span class="muted" id="clearMsg"></span><div><button class="ghost" id="refreshBtn">刷新</button><button class="ghost" id="clearAll">清理</button></div></div></section>`;
}
function showAndroidSection(section) {
  if (!IS_ANDROID_APP) return;
  const target = section === 'send' ? 'home' : section;
  androidHome.classList.toggle('hidden', target !== 'home');
  androidInbox.classList.toggle('hidden', target !== 'inbox');
  androidDrive.classList.toggle('hidden', target !== 'drive');
  if (section === 'send') { transferDrop.classList.remove('hidden'); androidSendOptions.classList.remove('hidden'); smartInput.focus(); }
  scrollTo({top:0, behavior:'smooth'});
}
function bindDrop(element, onFiles) {
  ['dragenter','dragover'].forEach(name => element.addEventListener(name, e => { e.preventDefault(); element.classList.add('active'); }));
  ['dragleave','drop'].forEach(name => element.addEventListener(name, e => { e.preventDefault(); element.classList.remove('active'); }));
  element.addEventListener('drop', e => { if (e.dataTransfer.files.length) onFiles(e.dataTransfer.files); });
}
let transferSelection = [];
function selectTransferFiles(files) {
  transferSelection = [...files];
  selectedFile.classList.toggle('hidden', !transferSelection.length);
  selectedFile.querySelector('span').textContent = transferSelection.length === 1 ? transferSelection[0].name : `已选择 ${transferSelection.length} 个文件`;
  if (IS_ANDROID_APP && transferSelection.length) document.getElementById('androidSendOptions').classList.remove('hidden');
}
async function uploadDriveFiles(files) {
  if (!files.length) return;
  const body = new FormData(); [...files].forEach(file => body.append('files', file));
  body.append('source_device', CURRENT_DEVICE); body.append('target_device', 'web'); body.append('web_visible', '1');
  await uploadForm(body); driveFiles.value = '';
}
async function sendTransfer() {
  const body = new FormData();
  body.append('source_device', CURRENT_DEVICE); body.append('target_device', targetDevice.value); body.append('web_visible', syncWeb.checked ? '1' : '0'); body.append('ttl', transferTtl.value);
  if (transferSelection.length) {
    transferSelection.forEach(file => body.append('files', file));
    await uploadForm(body); transferSelection = []; selectedFile.classList.add('hidden'); transferFiles.value = ''; transferImages.value = '';
  } else {
    const text = smartInput.value.trim(); if (!text) { fileMsg.textContent = '请先输入文本或选择文件'; return; }
    body.append('text', text); uploadBtn.disabled = true; uploadBtn.textContent = '发送中…';
    try { await api('/api/text', {method:'POST', body}); smartInput.value = ''; fileMsg.textContent = '已加入发送队列'; await Promise.all([loadItems(true), loadTransfers(), loadUsage()]); }
    catch (err) { fileMsg.textContent = err.message; }
    finally { uploadBtn.disabled = false; uploadBtn.textContent = '发送'; }
  }
}
async function loadDevices() {
  const data = await api('/api/devices', {cache:'no-store'});
  const previous = targetDevice.value;
  data.devices.forEach(d => deviceNames[d.id] = d.name);
  targetDevice.innerHTML = data.devices.filter(d => d.id !== 'web' && d.id !== 'windows' && d.id !== CURRENT_DEVICE).map(d => `<option value="${d.id}">${IS_ANDROID_APP || IS_MAC_APP ? '发送到：' : ''}${escapeHtml(d.name)}${d.online ? ' · 在线' : ' · 离线'}</option>`).join('');
  const values = [...targetDevice.options].map(o => o.value);
  const fallback = IS_ANDROID_APP ? 'mac' : 'android';
  targetDevice.value = previous && values.includes(previous) ? previous : (values.includes(fallback) ? fallback : values[0]);
  document.getElementById(IS_ANDROID_APP ? 'onlineCount' : IS_MAC_APP ? 'macOnlineCount' : 'webOnlineCount').textContent = `${data.devices.filter(d => d.online).length} 台设备在线`;
}
let glassToastTimer;
function showGlassToast(message) {
  let toast = document.getElementById('glassToast');
  if (!toast) { toast=document.createElement('div'); toast.id='glassToast'; toast.className='glass-toast'; document.body.appendChild(toast); }
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(glassToastTimer);
  glassToastTimer = setTimeout(() => toast.classList.remove('show'), 3000);
}
function copySyncLocalFileReady(deliveryKey, name) {
  const sent = String(deliveryKey || '').startsWith('sent:');
  const transfer = latestTransfers.find(t => sent ? ('sent:' + t.item_id === deliveryKey) : t.id === deliveryKey);
  if (transfer && !sent) transfer.status = 'downloaded';
  showGlassToast(sent ? '已保存到 CopySync 文件夹' : '接收完成：' + (name || '文件'));
  loadTransfers().catch(() => {});
}
function copySyncLocalFileFailed(deliveryKey, name) {
  showGlassToast('接收失败：' + (name || '文件'));
}
function readMacClipboard() {
  return new Promise((resolve, reject) => {
    window.__copysyncClipboardCallback = text => {
      window.__copysyncClipboardCallback = null;
      (typeof text === 'string') ? resolve(text) : reject(new Error('no text'));
    };
    window.webkit.messageHandlers.copySync.postMessage({type:'readClipboard'});
  });
}
async function copyToSystemClipboard(text) {
  if (IS_MAC_APP) {
    window.webkit.messageHandlers.copySync.postMessage({type:'copyText', text:String(text || '')});
    return;
  }
  if (IS_ANDROID_APP) {
    CopySyncNative.copyText(String(text || ''));
    return;
  }
  try {
    await navigator.clipboard.writeText(String(text || ''));
  } catch (error) {
    const field=document.createElement('textarea');
    field.value=String(text || ''); field.style.position='fixed'; field.style.opacity='0';
    document.body.appendChild(field); field.select(); document.execCommand('copy'); field.remove();
  }
}
async function copyDownloadLink(itemId) {
  const result = await api('/api/items/' + encodeURIComponent(itemId) + '/link', {cache:'no-store'});
  const link = result.url;
  if (IS_MAC_APP) {
    window.__copyDownloadUrl = link;
    return;
  }
  await copyToSystemClipboard(link);
}
async function loadTransfers() {
  const data = await api('/api/transfers', {cache:'no-store'});
  const relevant = (IS_ANDROID_APP || IS_MAC_APP) ? data.transfers.filter(t => t.source_device === CURRENT_DEVICE || t.target_device === CURRENT_DEVICE) : data.transfers;
  latestTransfers = relevant;
  const labels = {waiting:'等待接收', delivered:'已送达', downloaded:'已接收', copied:'已接收', failed:'失败'};
  if (IS_ANDROID_APP) {
    const seenItems = new Set();
    const inboxList = [];
    for (const t of relevant) {
      if (seenItems.has(t.item_id)) continue;
      seenItems.add(t.item_id);
      inboxList.push(t);
    }
    androidInboxShown = inboxList.slice(0,8);
    androidInboxList.innerHTML = androidInboxShown.length ? androidInboxShown.map(t => {
      const image = t.mime?.startsWith('image/');
      const icon = image ? `<img src="/download/${t.item_id}?inline=1" alt="">` : androidIcon(t.kind === 'text' ? 'note' : 'file');
      const incoming = t.target_device === CURRENT_DEVICE;
      const dir = incoming ? `来自 ${escapeHtml(deviceNames[t.source_device] || t.source_device)}` : `发至 ${escapeHtml(deviceNames[t.target_device] || t.target_device)}`;
      const second = t.kind === 'text' ? `<button class="act" data-tcopy="${t.item_id}">复制</button>` : `<button class="act" data-dl="${t.id}">下载</button>`;
      return `<div class="transfer-row" role="button" tabindex="0" data-receive="${t.id}"><div class="android-transfer-main"><div class="android-transfer-icon">${icon}</div><div><strong>${escapeHtml(t.kind === 'text' ? (t.text || '文本').slice(0,18) : t.name || '文件')}</strong><div class="muted">${dir} · ${fmtRemain(t.expires_at)}</div></div></div><div class="android-status"><button class="act" data-keep="${t.item_id}">上传</button>${second}</div></div>`;
    }).join('') : '<p class="muted">暂无内容</p>';
    const liveRows = relevant.map(t => ({...t, expired: false}));
    const historyRows = (data.history || []).filter(h => h.source_device === CURRENT_DEVICE || h.target_device === CURRENT_DEVICE).map(h => ({...h, expired: true}));
    const records = [...liveRows, ...historyRows].sort((a, b) => b.created_at - a.created_at).slice(0,8);
    const recordsHtml = records.length ? records.map(t => {
      const name = t.kind === 'text' ? (t.text || '文本').slice(0,18) : t.name || '文件';
      const status = t.expired ? '<span class="status expired">已过期 · 文件已删</span>' : `<span class="status ${t.status}">${labels[t.status] || t.status}</span>`;
      return `<div class="transfer-row ${t.expired ? 'expired' : ''}"><div><strong>${escapeHtml(name)}</strong><div class="muted">${escapeHtml(deviceNames[t.source_device] || t.source_device)} → ${escapeHtml(deviceNames[t.target_device] || t.target_device)}</div></div>${status}</div>`;
    }).join('') : '<p class="muted">暂无记录</p>';
    androidRecords.innerHTML = recordsHtml;
    androidInboxRecords.innerHTML = recordsHtml;
    androidInboxList.querySelectorAll('[data-keep]').forEach(b => b.onclick = e => { e.stopPropagation(); keepItem(b.dataset.keep); });
    androidInboxList.querySelectorAll('[data-tcopy]').forEach(b => b.onclick = e => { e.stopPropagation(); const t = latestTransfers.find(x => x.item_id === b.dataset.tcopy); if (t) copyToSystemClipboard(t.text || '').then(() => showGlassToast('文本已复制')); });
    androidInboxList.querySelectorAll('[data-dl]').forEach(b => b.onclick = e => { e.stopPropagation(); receiveTransfer(b.dataset.dl); });
  } else if (IS_MAC_APP) {
    const seenMacItems = new Set();
    const macFilesList = [];
    for (const t of relevant) {
      if (seenMacItems.has(t.item_id)) continue;
      seenMacItems.add(t.item_id);
      macFilesList.push(t);
    }
    macMyFiles.innerHTML = macFilesList.length ? macFilesList.slice(0,8).map(t => {
      const image = t.mime?.startsWith('image/');
      const icon = image ? `<img src="/download/${t.item_id}?inline=1" alt="">` : androidIcon(t.kind === 'text' ? 'note' : 'file');
      const incoming = t.target_device === CURRENT_DEVICE;
      const dir = incoming ? `来自 ${escapeHtml(deviceNames[t.source_device] || t.source_device)}` : `发至 ${escapeHtml(deviceNames[t.target_device] || t.target_device)}`;
      const second = t.kind === 'text' ? `<button class="act" data-tcopy="${t.item_id}">复制</button>` : `<button class="act" data-dl="${t.id}">下载</button>`;
      return `<div class="myfile-row" role="button" tabindex="0" data-receive="${t.id}"><div class="mthumb">${icon}</div><div class="myfile-copy"><div class="file-name">${escapeHtml(t.kind === 'text' ? (t.text || '文本').slice(0,42) : t.name || '文件')}</div><div class="muted">${dir} · ${fmtRemain(t.expires_at)}</div></div><div class="row-actions"><button class="act" data-keep="${t.item_id}">上传</button>${second}</div></div>`;
    }).join('') : '<p class="muted">暂无内容</p>';
    const macLiveRows = relevant.map(t => ({...t, expired: false}));
    const macHistoryRows = (data.history || []).filter(h => h.source_device === CURRENT_DEVICE || h.target_device === CURRENT_DEVICE).map(h => ({...h, expired: true}));
    const macRecordsMerged = [...macLiveRows, ...macHistoryRows].sort((a, b) => b.created_at - a.created_at).slice(0,12);
    macRecordsList.innerHTML = macRecordsMerged.length ? macRecordsMerged.map(t => {
      const name = t.kind === 'text' ? (t.text || '文本').slice(0,32) : t.name || '文件';
      const status = t.expired ? '<span class="status expired">已过期 · 文件已删</span>' : `<span class="status ${t.status}">${labels[t.status] || t.status}</span>`;
      return `<div class="transfer-row ${t.expired ? 'expired' : ''}"><div><strong>${escapeHtml(name)}</strong><div class="muted">${escapeHtml(deviceNames[t.source_device] || t.source_device)} → ${escapeHtml(deviceNames[t.target_device] || t.target_device)}</div></div>${status}</div>`;
    }).join('') : '<p class="muted">暂无记录</p>';
    macMyFiles.querySelectorAll('[data-keep]').forEach(b => b.onclick = e => { e.stopPropagation(); keepItem(b.dataset.keep); });
    macMyFiles.querySelectorAll('[data-tcopy]').forEach(b => b.onclick = e => { e.stopPropagation(); const t = latestTransfers.find(x => x.item_id === b.dataset.tcopy); if (t) copyToSystemClipboard(t.text || '').then(() => showGlassToast('文本已复制')); });
    macMyFiles.querySelectorAll('[data-dl]').forEach(b => b.onclick = e => { e.stopPropagation(); receiveTransfer(b.dataset.dl); });
  } else {
    const seenItems = new Set();
    const myFilesList = [];
    for (const t of data.transfers) {
      if (t.source_device === 'web' && t.target_device === 'web') continue;
      if (seenItems.has(t.item_id)) continue;
      seenItems.add(t.item_id);
      myFilesList.push(t);
    }
    myFiles.innerHTML = myFilesList.length ? myFilesList.slice(0,6).map(t => {
      const image = t.mime?.startsWith('image/');
      const icon = image ? `<img src="/download/${t.item_id}?inline=1" alt="">` : t.kind === 'text' ? '↗' : '📄';
      const dir = t.target_device === 'web' ? `来自 ${escapeHtml(deviceNames[t.source_device] || t.source_device)}` : `发至 ${escapeHtml(deviceNames[t.target_device] || t.target_device)}`;
      const second = t.kind === 'text' ? `<button class="act" data-tcopy="${t.item_id}">复制</button>` : `<a class="act" href="/download/${t.item_id}" download>下载</a>`;
      return `<div class="myfile-row"><div class="mthumb">${icon}</div><div class="myfile-copy"><div class="file-name">${escapeHtml(t.kind === 'text' ? (t.text || '文本').slice(0,42) : t.name || '文件')}</div><div class="muted">${dir} · ${fmtRemain(t.expires_at)}</div></div><div class="row-actions"><button class="act" data-keep="${t.item_id}">上传</button>${second}</div></div>`;
    }).join('') : '<p class="muted">暂无内容</p>';
    const liveRows = data.transfers.filter(t => !(t.source_device === 'web' && t.target_device === 'web')).map(t => ({...t, expired: false}));
    const historyRows = (data.history || []).map(h => ({...h, expired: true}));
    const records = [...liveRows, ...historyRows].sort((a, b) => b.created_at - a.created_at).slice(0,8);
    transferRecords.innerHTML = records.length ? records.map(t => {
      const name = t.kind === 'text' ? (t.text || '文本').slice(0,24) : t.name || '文件';
      const status = t.expired ? '<span class="status expired">已过期 · 文件已删</span>' : `<span class="status ${t.status}">${labels[t.status] || t.status}</span>`;
      return `<div class="transfer-row ${t.expired ? 'expired' : ''}"><div><strong>${escapeHtml(name)}</strong><div class="muted">${escapeHtml(deviceNames[t.source_device] || t.source_device)} → ${escapeHtml(deviceNames[t.target_device] || t.target_device)}</div></div>${status}</div>`;
    }).join('') : '<p class="muted">暂无记录</p>';
    myFiles.querySelectorAll('[data-keep]').forEach(b => b.onclick = () => keepItem(b.dataset.keep));
    myFiles.querySelectorAll('[data-tcopy]').forEach(b => b.onclick = () => { const t = latestTransfers.find(x => x.item_id === b.dataset.tcopy); if (t) copyToSystemClipboard(t.text || '').then(() => showGlassToast('文本已复制')); });
  }
  document.querySelectorAll('[data-receive]').forEach(row => {
    row.onclick = () => { if (row.dataset.suppressClick === '1') return; receiveTransfer(row.dataset.receive); };
    row.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); receiveTransfer(row.dataset.receive); } };
  });
  if (IS_ANDROID_APP) {
    const container = androidInboxList;
    const shown = androidInboxShown;
    container.querySelectorAll('.transfer-row').forEach((row, index) => {
      const transfer = shown[index];
      if (!transfer || transfer.kind === 'text') return;
      const copyLink = document.createElement('button');
      copyLink.type = 'button'; copyLink.className = 'swipe-link'; copyLink.textContent = '复制下载链接';
      copyLink.onclick = async event => {
        event.stopPropagation();
        await copyDownloadLink(transfer.item_id);
        showGlassToast('下载链接已复制');
      };
      row.appendChild(copyLink);
      let startX = 0, startY = 0;
      row.addEventListener('pointerdown', event => { startX=event.clientX; startY=event.clientY; });
      row.addEventListener('pointerup', event => { const dx=event.clientX-startX, dy=event.clientY-startY; if (Math.abs(dx)>Math.abs(dy) && Math.abs(dx)>35) { row.dataset.suppressClick='1'; setTimeout(()=>delete row.dataset.suppressClick,250); if (dx>45) row.classList.add('swiped'); else row.classList.remove('swiped'); } });
    });
  }
}
async function keepItem(itemId) {
  try {
    await api('/api/items/' + encodeURIComponent(itemId) + '/keep', {method:'POST'});
    showGlassToast('已转存到临时网盘');
    await Promise.all([loadItems(true), loadTransfers(), loadUsage()]);
  } catch (err) { showGlassToast('转存失败：' + err.message); }
}
async function receiveTransfer(deliveryId) {
  const transfer = latestTransfers.find(t => t.id === deliveryId);
  if (!transfer) return;
  try {
    if ((IS_ANDROID_APP || IS_MAC_APP) && transfer.source_device === CURRENT_DEVICE && transfer.target_device !== CURRENT_DEVICE && transfer.kind !== 'text') {
      if (IS_MAC_APP) window.webkit.messageHandlers.copySync.postMessage({type:'saveSent', item_id:transfer.item_id, name:transfer.name || 'CopySync-file'});
      else {
        const localKey = 'sent:' + transfer.item_id;
        const localState = CopySyncNative.localFileState(localKey);
        CopySyncNative.saveSent(transfer.item_id, transfer.name || 'CopySync-file', transfer.mime || 'application/octet-stream');
        showGlassToast(localState === 'ready' ? '已在文件管理器中定位已发送文件' : localState === 'pending' ? '已发送文件正在保存，请稍候' : localState === 'deleted' ? '本地文件已删除，正在重新保存已发送文件' : '正在保存已发送文件');
        return;
      }
      showGlassToast('正在 Finder 中定位已发送文件');
      return;
    }
    if (transfer.kind === 'text') {
      await copyToSystemClipboard(transfer.text || '');
      showGlassToast('文本已复制');
    } else {
      const incoming = transfer.target_device === CURRENT_DEVICE;
      if (IS_MAC_APP && incoming) {
        window.webkit.messageHandlers.copySync.postMessage({type:'revealReceived', id:transfer.id, name:transfer.name || 'CopySync-file'});
        showGlassToast('正在 Finder 中显示接收文件');
        return;
      }
      if (IS_ANDROID_APP && incoming) {
        const localState = CopySyncNative.localFileState(transfer.id);
        if (localState === 'ready') {
          CopySyncNative.revealReceived(transfer.id, transfer.item_id, transfer.name || 'CopySync-file', transfer.mime || 'application/octet-stream');
          showGlassToast('已在文件管理器中定位接收文件');
        } else if (localState === 'pending') {
          showGlassToast('文件正在接收，请稍候');
        } else {
          CopySyncNative.receiveFile(transfer.id, transfer.item_id, transfer.name || 'CopySync-file', transfer.mime || 'application/octet-stream');
          showGlassToast((localState === 'deleted' ? '本地文件已删除，正在重新接收 ' : '正在接收 ') + (transfer.name || '文件'));
        }
        return;
      }
      const link = document.createElement('a');
      link.href = '/download/' + transfer.item_id;
      link.download = transfer.name || 'CopySync-download';
      document.body.appendChild(link); link.click(); link.remove();
      fileMsg.textContent = '已开始下载 ' + (transfer.name || '文件');
    }
    const body = new URLSearchParams({status: transfer.kind === 'text' ? 'copied' : 'downloaded'});
    await api('/api/deliveries/' + transfer.id + '/ack', {method:'POST', body});
    await loadTransfers();
  } catch (err) { if (IS_ANDROID_APP || IS_MAC_APP) showGlassToast('操作失败：' + err.message); else fileMsg.textContent = '接收失败：' + err.message; }
}
async function loadUsage() {
  const u = await api('/api/usage', {cache:'no-store'}); capacity.textContent = `临时 ${fmtSize(u.temporary)} / ${fmtSize(u.temporary_limit)} · 固定 ${fmtSize(u.pinned)}`;
}
async function refreshAll() {
  await Promise.all([loadItems(true), loadTransfers(), loadDevices(), loadUsage()]);
}
window.refreshAll = refreshAll;
window.pullRefresh = async () => {
  try { await refreshAll(); showGlassToast('已刷新'); } catch {}
  finally { if (IS_ANDROID_APP && window.CopySyncNative?.refreshDone) CopySyncNative.refreshDone(); }
};
async function uploadSmart() {
  if (fileInput.files.length) {
    const body = new FormData();
    [...fileInput.files].forEach(file => body.append('files', file));
    return uploadForm(body);
  }
  const text = smartInput.value.trim();
  if (!text) return;
  const body = new FormData();
  body.append('text', text);
  uploadBtn.disabled = true;
  uploadBtn.textContent = '上传中';
  try {
    await api('/api/text', {method:'POST', body});
    smartInput.value = '';
    uploadBtn.textContent = '已上传';
    loadItems(true);
  } catch (err) { uploadBtn.textContent = '上传失败'; fileMsg.textContent = err.message; }
  finally { setTimeout(() => { uploadBtn.disabled = false; uploadBtn.textContent = '上传'; }, 1200); }
}
async function uploadForm(body) {
  uploadBtn.disabled = true;
  uploadBtn.textContent = '发送中…';
  try { await api('/api/upload', {method:'POST', body}); fileMsg.textContent = '已加入发送队列'; uploadBtn.textContent = '已发送'; await Promise.all([loadItems(true), loadTransfers(), loadUsage()]); }
  catch (err) { uploadBtn.textContent = '发送失败'; fileMsg.textContent = err.message; }
  finally { setTimeout(() => { uploadBtn.disabled = false; uploadBtn.textContent = '发送'; }, 1000); }
}
async function refreshNow(btn) {
  const button = btn || document.getElementById('refreshBtn');
  const old = button.textContent;
  button.disabled = true;
  button.textContent = '刷新中';
  try { await Promise.all([loadItems(true), loadTransfers(), loadDevices(), loadUsage()]); button.textContent = '已刷新'; }
  catch (err) { button.textContent = '刷新失败'; }
  finally { setTimeout(() => { button.disabled = false; button.textContent = old; }, 1200); }
}
async function loadItems(force=false) {
  const data = await api('/api/items', {cache:'no-store'});
  const fingerprint = JSON.stringify(data.items);
  if (!force && fingerprint === itemsFingerprint) return;
  itemsFingerprint = fingerprint;
  allItems = data.items;
  renderItems();
}
function renderItems() {
  const q = (document.getElementById('searchInput')?.value || '').trim().toLowerCase();
  const kind = document.querySelector('.chip.active')?.dataset.kind || '';
  const visible = allItems.filter(i => {
    const hay = `${i.name || ''} ${i.text || ''}`.toLowerCase();
    return (!q || hay.includes(q)) &&
      (!kind || (kind === 'text' && i.kind === 'text') || (kind === 'image' && i.mime.startsWith('image/')) || (kind === 'file' && i.kind !== 'text' && !i.mime.startsWith('image/')) || (kind === 'pinned' && i.pinned));
  });
  items.innerHTML = visible.length ? visible.map(itemHtml).join('') : '<div class="empty">这里还没有内容</div>';
  document.querySelectorAll('[data-pin]').forEach(b => b.onclick = () => { b.classList.toggle('off'); b.classList.toggle('on'); mutate('/api/items/' + b.dataset.pin + '/pin'); });
  document.querySelectorAll('[data-extend]').forEach(b => b.onclick = () => mutate('/api/items/' + b.dataset.extend + '/extend'));
  document.querySelectorAll('[data-del]').forEach(b => b.onclick = () => confirm(b.dataset.pinned === '1' ? '这是已钉住内容，确认删除？' : '删除这条内容？') && mutate('/api/items/' + b.dataset.del, 'DELETE'));
  document.querySelectorAll('[data-copy]').forEach(b => b.onclick = () => copyItem(b));
  document.querySelectorAll('[data-download]').forEach(b => b.onclick = () => {
    const old = b.textContent;
    b.textContent = '已开始';
    setTimeout(() => b.textContent = old, 1200);
  });
  document.querySelectorAll('[data-note]').forEach(b => b.onclick = () => saveNote(b));
}
async function copyItem(button) {
  const item = allItems.find(i => i.id === button.dataset.copy);
  if (!item) return;
  const old = button.textContent;
  try {
    if (item.kind === 'text') {
      await navigator.clipboard.writeText(item.text);
    } else if (item.mime.startsWith('image/') && item.mime !== 'image/svg+xml') {
      const source = await (await fetch('/download/' + item.id + '?inline=1', {cache:'no-store'})).blob();
      const image = await createImageBitmap(source);
      const canvas = document.createElement('canvas');
      canvas.width = image.width; canvas.height = image.height;
      canvas.getContext('2d').drawImage(image, 0, 0);
      const png = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
      await navigator.clipboard.write([new ClipboardItem({'image/png': png})]);
    } else {
      const result = await api('/api/items/' + encodeURIComponent(item.id) + '/link', {cache:'no-store'});
      await navigator.clipboard.writeText(result.url);
    }
    button.textContent = '已复制';
  } catch (err) {
    button.textContent = '复制失败';
  }
  setTimeout(() => button.textContent = old, 1200);
}
async function saveNote(button) {
  const body = new FormData();
  body.append('note', document.getElementById('note-' + button.dataset.note).value.trim());
  await api('/api/items/' + button.dataset.note + '/note', {method:'POST', body});
  button.textContent = '已保存';
  setTimeout(() => button.textContent = '保存', 1200);
}
function itemHtml(i) {
  const isImage = i.mime.startsWith('image/') && i.mime !== 'image/svg+xml';
  const icon = isImage ? `<img src="/download/${i.id}?inline=1" alt="">` : i.kind === 'text' ? 'T' : '📄';
  const title = i.kind === 'text' ? (i.text || '文本').split('\\n')[0] : i.name;
  const subtitle = i.kind === 'text' ? (i.text || '').replace(/\\s+/g,' ').slice(0,90) : `${fmtSize(i.size)} · ${i.mime || '文件'}`;
  return `<article class="file-row"><button class="pin ${i.pinned ? 'on' : 'off'}" data-pin="${i.id}" aria-label="${i.pinned ? '取消钉住' : '钉住'}">📌</button><div class="file-main"><div class="file-icon">${icon}</div><div class="file-copy"><div class="file-name">${escapeHtml(title)}</div><div class="file-preview">${escapeHtml(subtitle)}</div><div class="muted">${fmtTime(i.created_at)} · ${i.pinned ? '已钉住 · 永久保留' : fmtExpire(i.expires_at)}</div></div></div><div class="row-actions">${i.pinned ? '' : `<button class="act" data-extend="${i.id}">续期</button>`}<button class="act" data-copy="${i.id}">复制</button><a class="act" data-download="${i.id}" href="/download/${i.id}" download>下载</a><button class="act" data-del="${i.id}" data-pinned="${i.pinned ? 1 : 0}" aria-label="删除">✕</button></div></article>`;
}
async function mutate(path, method='POST') { await api(path, {method}); loadItems(); }
async function clearItems(path) {
  const result = await api(path, {method:'POST'});
  clearMsg.textContent = `已删除 ${result.deleted} 项，释放 ${fmtSize(result.bytes)}`;
  loadItems();
}
function escapeHtml(s) { return (s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
route();
</script></main></body></html>
""".replace("__DIRECT_URL__", DIRECT_URL).replace("__CF_URL__", CF_URL)


def index_html(force_go=False):
    return INDEX_HTML.replace("__FORCE_GO__", "true" if force_go else "false").encode()


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("pragma foreign_keys=on")
    conn.execute("pragma journal_mode=wal")
    conn.execute("pragma busy_timeout=5000")
    return conn


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def record_change(conn, entity, entity_id, op):
    conn.execute(
        "insert into sync_changes(entity, entity_id, op, created_at) values(?,?,?,?)",
        (entity, entity_id, op, now_iso()),
    )
    conn.execute(
        "delete from sync_changes where seq < (select max(seq) from sync_changes) - ?",
        (SYNC_KEEP,),
    )


def idem_replay(conn, device_id, key):
    row = conn.execute(
        "select result_json from idempotency_keys where device_id=? and idem_key=? and expires_at > ?",
        (device_id, key, now_iso()),
    ).fetchone()
    return json.loads(row["result_json"]) if row else None


def idem_store(conn, device_id, key, result):
    expires = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 24 * 3600))
    conn.execute(
        "insert into idempotency_keys(device_id, idem_key, result_json, created_at, expires_at) values(?,?,?,?,?) "
        "on conflict(device_id, idem_key) do update set result_json=excluded.result_json, "
        "created_at=excluded.created_at, expires_at=excluded.expires_at",
        (device_id, key, json.dumps(result, ensure_ascii=False), now_iso(), expires),
    )


def init():
    if not SESSION_SECRET:
        raise SystemExit("Set WEBCLIP_SESSION_SECRET first.")
    FILES_DIR.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.executescript(
            """
            create table if not exists items (
              id text primary key,
              kind text not null,
              name text not null,
              stored_name text,
              mime text not null default 'application/octet-stream',
              size integer not null default 0,
              text text,
              note text not null default '',
              pinned integer not null default 0,
              created_at integer not null,
              expires_at integer
            );
            create index if not exists idx_items_expires on items(expires_at);
            create table if not exists login_failures (
              ip text primary key,
              count integer not null,
              updated_at integer not null
            );
            create table if not exists settings (
              key text primary key,
              value text not null
            );
            create table if not exists devices (
              id text primary key,
              name text not null,
              platform text not null,
              last_seen_at integer not null default 0,
              enabled integer not null default 1
            );
            create table if not exists deliveries (
              id text primary key,
              item_id text not null,
              source_device text not null,
              target_device text not null,
              status text not null default 'waiting',
              created_at integer not null,
              updated_at integer not null,
              foreign key(item_id) references items(id) on delete cascade
            );
            create index if not exists idx_deliveries_item on deliveries(item_id);
            create index if not exists idx_deliveries_target on deliveries(target_device, created_at desc);
            create table if not exists transfer_history (
              id text primary key,
              item_id text not null,
              source_device text not null,
              target_device text not null,
              status text not null,
              kind text not null default 'file',
              name text not null default '',
              mime text not null default '',
              size integer not null default 0,
              text text,
              created_at integer not null,
              expired_at integer not null
            );
            create index if not exists idx_transfer_history_created on transfer_history(created_at desc);
            """
        )
        columns = {row["name"] for row in conn.execute("pragma table_info(items)")}
        if "note" not in columns:
            conn.execute("alter table items add column note text not null default ''")
        for name, definition in (
            ("source_device", "text not null default 'web'"),
            ("target_device", "text not null default 'all'"),
            ("web_visible", "integer not null default 1"),
            ("client_item_id", "text"),
        ):
            if name not in columns:
                conn.execute(f"alter table items add column {name} {definition}")
        now = int(time.time())
        for device_id, name, platform in (
            ("mac", "Mac", "mac"),
            ("android", "Android 手机", "android"),
            ("web", "网页临时设备", "web"),
        ):
            conn.execute(
                "insert into devices(id,name,platform,last_seen_at) values(?,?,?,?) on conflict(id) do nothing",
                (device_id, name, platform, now if device_id == "web" else 0),
            )
        conn.execute("update devices set name='Mac', enabled=1 where id='mac'")
        conn.execute("delete from devices where id='windows'")
        if not get_setting(conn, "password_hash"):
            if not PASSWORD_HASH and not PASSWORD:
                raise SystemExit("Set WEBCLIP_PASSWORD or WEBCLIP_PASSWORD_HASH for first run.")
            set_setting(conn, "password_hash", PASSWORD_HASH or hash_password(PASSWORD))
        if not get_setting(conn, "session_version"):
            set_setting(conn, "session_version", "1")
        migrate_v1(conn)


def migrate_v1(conn):
    conn.executescript(
        """
        create table if not exists device_tokens (
          id integer primary key,
          device_id text not null,
          token_hash text not null unique,
          created_at text not null,
          last_used_at text,
          revoked_at text
        );
        create table if not exists item_blobs (
          id integer primary key,
          item_id text not null,
          variant text not null,
          stored_name text not null,
          mime text not null default '',
          size integer not null default 0,
          sha256 text,
          created_at text not null,
          unique(item_id, variant, stored_name)
        );
        create table if not exists sync_changes (
          seq integer primary key autoincrement,
          entity text not null,
          entity_id text not null,
          op text not null,
          created_at text not null
        );
        create index if not exists idx_sync_changes_seq on sync_changes(seq);
        create table if not exists idempotency_keys (
          device_id text not null,
          idem_key text not null,
          result_json text not null,
          created_at text not null,
          expires_at text not null,
          primary key(device_id, idem_key)
        );
        """
    )
    rows = conn.execute(
        "select i.id, i.stored_name, i.mime, i.size from items i "
        "where i.stored_name != '' and not exists ("
        "  select 1 from item_blobs b where b.item_id = i.id and b.variant = 'original')"
    ).fetchall()
    for item_id, stored, mime, size in rows:
        path = FILES_DIR / stored
        if not path.exists():
            continue
        conn.execute(
            "insert into item_blobs(item_id, variant, stored_name, mime, size, sha256, created_at) "
            "values (?,?,?,?,?,?,?)",
            (item_id, "original", stored, mime, size, sha256_file(path), now_iso()),
        )


def sign(value):
    mac = hmac.new(SESSION_SECRET.encode(), value.encode(), hashlib.sha256).digest()
    return value + "." + base64.urlsafe_b64encode(mac).decode().rstrip("=")


def unsign(value):
    try:
        raw, sig = value.rsplit(".", 1)
    except ValueError:
        return ""
    return raw if hmac.compare_digest(sign(raw), value) else ""


def download_token_valid(item_id, token):
    return bool(token) and unsign(token) == "download:" + item_id


def signed_download_url(item_id):
    token = sign("download:" + item_id)
    return DIRECT_URL.rstrip("/") + "/download/" + urllib.parse.quote(item_id, safe="") + "?" + urllib.parse.urlencode({"token": token})


def b64decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def hash_password(password):
    salt = secrets.token_bytes(16)
    rounds = 260_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds)
    return "pbkdf2_sha256${}${}${}".format(
        rounds,
        base64.urlsafe_b64encode(salt).decode().rstrip("="),
        base64.urlsafe_b64encode(digest).decode().rstrip("="),
    )


def password_ok(password):
    with db() as conn:
        stored = get_setting(conn, "password_hash")
    try:
        algo, rounds, salt, digest = stored.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), b64decode(salt), int(rounds))
        return hmac.compare_digest(b64decode(digest), actual)
    except Exception:
        return False


def issue_device_token(conn, device_id):
    raw = "cps_" + secrets.token_urlsafe(32)
    conn.execute(
        "insert into device_tokens(device_id, token_hash, created_at) values(?,?,?)",
        (device_id, hashlib.sha256(raw.encode()).hexdigest(), now_iso()),
    )
    return raw


def get_setting(conn, key):
    row = conn.execute("select value from settings where key=?", (key,)).fetchone()
    return row["value"] if row else ""


def set_setting(conn, key, value):
    conn.execute("insert into settings(key,value) values(?,?) on conflict(key) do update set value=excluded.value", (key, value))


def session_version():
    with db() as conn:
        return int(get_setting(conn, "session_version") or "1")


def make_session_cookie(version=None):
    now = int(time.time())
    max_age = 30 * 86400
    token = sign(f"{USERNAME}:{now + max_age}:{version or session_version()}:{secrets.token_urlsafe(16)}")
    morsel = cookies.SimpleCookie()
    morsel["webclip_session"] = token
    morsel["webclip_session"]["path"] = "/"
    morsel["webclip_session"]["httponly"] = True
    morsel["webclip_session"]["max-age"] = str(max_age)
    morsel["webclip_session"]["expires"] = email.utils.formatdate(now + max_age, usegmt=True)
    if COOKIE_SECURE:
        morsel["webclip_session"]["secure"] = True
    morsel["webclip_session"]["samesite"] = "Lax"
    if COOKIE_DOMAIN:
        morsel["webclip_session"]["domain"] = COOKIE_DOMAIN
    return morsel.output(header="").strip()


def clear_session_cookie():
    morsel = cookies.SimpleCookie()
    morsel["webclip_session"] = ""
    morsel["webclip_session"]["path"] = "/"
    morsel["webclip_session"]["max-age"] = "0"
    if COOKIE_SECURE:
        morsel["webclip_session"]["secure"] = True
    if COOKIE_DOMAIN:
        morsel["webclip_session"]["domain"] = COOKIE_DOMAIN
    return morsel.output(header="").strip()


def make_v1_cookie(token):
    morsel = cookies.SimpleCookie()
    morsel["webclip_v1"] = token
    morsel["webclip_v1"]["path"] = "/"
    morsel["webclip_v1"]["httponly"] = True
    morsel["webclip_v1"]["max-age"] = "2592000"
    morsel["webclip_v1"]["secure"] = True
    morsel["webclip_v1"]["samesite"] = "Lax"
    if COOKIE_DOMAIN:
        morsel["webclip_v1"]["domain"] = COOKIE_DOMAIN
    return morsel.output(header="").strip()


def clear_v1_cookie():
    morsel = cookies.SimpleCookie()
    morsel["webclip_v1"] = ""
    morsel["webclip_v1"]["path"] = "/"
    morsel["webclip_v1"]["httponly"] = True
    morsel["webclip_v1"]["max-age"] = "0"
    morsel["webclip_v1"]["secure"] = True
    morsel["webclip_v1"]["samesite"] = "Lax"
    if COOKIE_DOMAIN:
        morsel["webclip_v1"]["domain"] = COOKIE_DOMAIN
    return morsel.output(header="").strip()


def strong_enough(password):
    return len(password) >= 12


def client_ip(handler):
    peer = handler.client_address[0]
    try:
        if not ipaddress.ip_address(peer).is_loopback:
            return peer
    except ValueError:
        return peer
    forwarded = handler.headers.get("x-real-ip", "").strip()
    if forwarded:
        return forwarded
    return peer


def safe_filename(filename):
    name = Path(filename).name.strip().replace("\x00", "")
    if not name:
        name = "file"
    return name[:255]


def json_bytes(data):
    return json.dumps(data, ensure_ascii=False).encode()


class AbortRequest(Exception):
    pass


class FormField:
    def __init__(self, value=b"", filename=""):
        self.filename = filename
        self.file = io.BytesIO(value.encode() if isinstance(value, str) else value)
        self.value = value.decode(errors="replace") if isinstance(value, bytes) else value

    def __str__(self):
        return self.value


class Form:
    def __init__(self):
        self.fields = {}

    def add(self, name, field):
        if name in self.fields:
            current = self.fields[name]
            if isinstance(current, list):
                current.append(field)
            else:
                self.fields[name] = [current, field]
        else:
            self.fields[name] = field

    def getfirst(self, name, default=""):
        value = self.fields.get(name)
        if isinstance(value, list):
            value = value[0]
        return str(value) if value is not None else default

    def __getitem__(self, name):
        return self.fields[name]


def parse_form(body, content_type):
    form = Form()
    if content_type.startswith("application/x-www-form-urlencoded"):
        for key, values in urllib.parse.parse_qs(body.decode(), keep_blank_values=True).items():
            for value in values:
                form.add(key, FormField(value))
        return form
    if content_type.startswith("multipart/form-data"):
        raw = f"Content-Type: {content_type}\nMIME-Version: 1.0\n\n".encode() + body
        msg = email.message_from_bytes(raw, policy=email.policy.default)
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if not name:
                continue
            form.add(name, FormField(part.get_payload(decode=True) or b"", part.get_filename() or ""))
        return form
    return form


def cleanup(include_orphans=False):
    now = int(time.time())
    deleted = 0
    freed = 0
    with db() as conn:
        pending_guard = "and not exists (select 1 from deliveries d where d.item_id=items.id and d.status='waiting')"
        rows = conn.execute(
            f"select id, stored_name from items where pinned=0 and expires_at is not null and expires_at <= ? {pending_guard}",
            (now,),
        ).fetchall()
        for row in rows:
            if row["stored_name"]:
                freed += unlink_file(row["stored_name"])
            deleted += 1
        conn.execute(
            "insert into transfer_history(id,item_id,source_device,target_device,status,kind,name,mime,size,text,created_at,expired_at) "
            "select d.id, d.item_id, d.source_device, d.target_device, d.status, i.kind, i.name, i.mime, i.size, i.text, d.created_at, ? "
            "from deliveries d join items i on i.id=d.item_id "
            "where i.pinned=0 and i.expires_at is not null and i.expires_at <= ? "
            "and not exists (select 1 from deliveries w where w.item_id=i.id and w.status='waiting') "
            "on conflict(id) do update set status=excluded.status, expired_at=excluded.expired_at",
            (now, now),
        )
        conn.execute(
            f"delete from items where pinned=0 and expires_at is not null and expires_at <= ? {pending_guard}",
            (now,),
        )
        conn.execute("delete from transfer_history where created_at < ?", (now - TRANSFER_HISTORY_TTL_SECONDS,))
        for row in conn.execute("select id, stored_name from items where kind='file' and stored_name is not null").fetchall():
            if not (FILES_DIR / row["stored_name"]).exists():
                conn.execute("delete from items where id=?", (row["id"],))
                deleted += 1
        known = {r["stored_name"] for r in conn.execute("select stored_name from items where stored_name is not null")}
    for path in FILES_DIR.glob("*.part"):
        if now - path.stat().st_mtime > 3600:
            freed += path.stat().st_size
            path.unlink(missing_ok=True)
    if include_orphans:
        for path in FILES_DIR.iterdir():
            if path.is_file() and path.name not in known:
                freed += path.stat().st_size
                path.unlink(missing_ok=True)
    if deleted or freed:
        print(f"cleanup deleted={deleted} freed={freed}")
        notify_items_changed()
    return {"deleted": deleted, "bytes": freed}


def notify_items_changed():
    global ITEMS_VERSION
    with ITEM_EVENTS:
        ITEMS_VERSION += 1
        ITEM_EVENTS.notify_all()


def unlink_file(stored_name):
    path = FILES_DIR / stored_name
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return 0
    path.unlink(missing_ok=True)
    return size


def delete_items(where, params=()):
    deleted = 0
    freed = 0
    with db() as conn:
        rows = conn.execute("select id, stored_name, size from items " + where, params).fetchall()
        for row in rows:
            if row["stored_name"]:
                freed += unlink_file(row["stored_name"])
            else:
                freed += row["size"]
            deleted += 1
        conn.execute("delete from items " + where, params)
    return {"deleted": deleted, "bytes": freed}


def usage():
    with db() as conn:
        row = conn.execute("select coalesce(sum(case when pinned=1 then size else 0 end),0) p, coalesce(sum(case when pinned=0 then size else 0 end),0) t from items").fetchone()
    disk = shutil.disk_usage(DATA_DIR)
    return row["p"], row["t"], disk.used / disk.total


def create_delivery(conn, item_id, source_device="web", target_device="all"):
    now = int(time.time())
    source_device = source_device or "web"
    target_device = target_device or "all"
    if target_device == "windows":
        target_device = "all"
    if target_device == "all":
        targets = [
            row["id"] for row in conn.execute(
                "select id from devices where enabled=1 and id not in ('web', 'windows', ?)",
                (source_device,),
            )
        ]
    else:
        targets = [target_device]
    if not targets:
        targets = ["web"]
    delivery_ids = []
    for target in targets:
        delivery_id = secrets.token_urlsafe(12)
        conn.execute(
            "insert into deliveries(id,item_id,source_device,target_device,status,created_at,updated_at) values(?,?,?,?,?,?,?)",
            (delivery_id, item_id, source_device, target, "delivered" if target == "web" else "waiting", now, now),
        )
        delivery_ids.append(delivery_id)
    return delivery_ids[0]


def form_int(form, name, default, minimum=None, maximum=None):
    try:
        value = int(form.getfirst(name, str(default)))
    except (TypeError, ValueError):
        value = default
    if minimum is not None:
        value = max(minimum, value)
    if maximum is not None:
        value = min(maximum, value)
    return value


class Handler(BaseHTTPRequestHandler):
    server_version = "WebClipboard/0.1"

    def do_GET(self):
        try:
            if self.path.startswith("/api/v1/"):
                return self.route_v1()
            cleanup()
            path = urllib.parse.urlparse(self.path).path
            host = self.headers.get("host", "").split(":", 1)[0].lower()
            if path == "/go" or (path == "/" and host in GO_ONLY_HOSTS):
                self.send(200, index_html(True), "text/html; charset=utf-8")
            elif path == "/":
                self.send(200, index_html(False), "text/html; charset=utf-8")
            elif path == "/healthz":
                self.send(200, b"ok", "text/plain")
            elif path == "/probe":
                self.send_probe()
            elif path == "/favicon.png" and FAVICON_PATH.is_file():
                self.send(200, FAVICON_PATH.read_bytes(), "image/png")
            elif path.startswith("/api/update/"):
                self.send_update_manifest(path.rsplit("/", 1)[-1])
            elif path.startswith("/updates/"):
                self.send_update_file(urllib.parse.unquote(path.rsplit("/", 1)[-1]))
            elif path == "/api/me":
                self.require_auth()
                self.send_json({"ok": True}, {"Set-Cookie": make_session_cookie()})
            elif path == "/api/items":
                self.require_auth()
                self.list_items()
            elif path.startswith("/api/items/") and path.endswith("/link"):
                self.require_auth()
                self.send_download_link(urllib.parse.unquote(path[len("/api/items/"):-len("/link")]))
            elif path == "/api/devices":
                self.require_auth()
                self.list_devices()
            elif path == "/api/transfers":
                self.require_auth()
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                self.list_transfers(query.get("device", [""])[0])
            elif path == "/api/usage":
                self.require_auth()
                pinned, temporary, disk_used = usage()
                self.send_json({"pinned": pinned, "temporary": temporary, "disk_used": disk_used,
                                "pinned_limit": PINNED_LIMIT_BYTES, "temporary_limit": TEMP_LIMIT_BYTES})
            elif path == "/api/events":
                self.require_auth()
                self.stream_events()
            elif path.startswith("/download/"):
                item_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
                query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                if not self.authed() and not download_token_valid(item_id, query.get("token", [""])[0]):
                    self.fail(401, "login required")
                self.download(item_id)
            else:
                self.send_error(404)
        except AbortRequest:
            pass

    def do_OPTIONS(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/probe":
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Max-Age", "86400")
            self.end_headers()
        else:
            self.send_error(404)

    def do_HEAD(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "2")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
        else:
            self.send_error(404)

    def do_POST(self):
        try:
            if self.path.startswith("/api/v1/"):
                return self.route_v1()
            cleanup()
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/login":
                self.login()
            elif path == "/api/logout":
                self.logout()
            elif path == "/api/text":
                self.require_auth()
                self.add_text()
                notify_items_changed()
            elif path == "/api/upload":
                self.require_auth()
                self.upload()
                notify_items_changed()
            elif path == "/api/password":
                self.require_auth()
                self.change_password()
            elif path == "/api/clear-temp":
                self.require_auth()
                self.clear_temp()
                notify_items_changed()
            elif path == "/api/clear-all":
                self.require_auth()
                self.clear_all()
                notify_items_changed()
            elif path.startswith("/api/items/") and path.endswith("/extend"):
                self.require_auth()
                self.extend_item(path.split("/")[-2])
                notify_items_changed()
            elif path.startswith("/api/items/") and path.endswith("/keep"):
                self.require_auth()
                self.keep_item(path.split("/")[-2])
                notify_items_changed()
            elif path.startswith("/api/items/") and path.endswith("/pin"):
                self.require_auth()
                self.toggle_pin(path.split("/")[-2])
                notify_items_changed()
            elif path.startswith("/api/items/") and path.endswith("/note"):
                self.require_auth()
                self.update_note(path.split("/")[-2])
                notify_items_changed()
            elif path.startswith("/api/items/") and path.endswith("/send"):
                self.require_auth()
                self.send_existing_item(path.split("/")[-2])
                notify_items_changed()
            elif path.startswith("/api/deliveries/") and path.endswith("/ack"):
                self.require_auth()
                self.ack_delivery(path.split("/")[-2])
                notify_items_changed()
            elif path.startswith("/api/devices/") and path.endswith("/heartbeat"):
                self.require_auth()
                self.heartbeat(path.split("/")[-2])
                notify_items_changed()
            else:
                self.send_error(404)
        except AbortRequest:
            pass

    def do_DELETE(self):
        try:
            if self.path.startswith("/api/v1/"):
                return self.route_v1()
            path = urllib.parse.urlparse(self.path).path
            if path.startswith("/api/items/"):
                self.require_auth()
                self.delete_item(path.rsplit("/", 1)[-1])
                notify_items_changed()
            else:
                self.send_error(404)
        except AbortRequest:
            pass

    def do_PATCH(self):
        try:
            if self.path.startswith("/api/v1/"):
                return self.route_v1()
            self.send_error(404)
        except AbortRequest:
            pass

    def route_v1(self):
        path = urllib.parse.urlsplit(self.path).path
        method = self.command
        if path == "/api/v1/auth/login" and method == "POST":
            return self.v1_login()
        if path == "/api/v1/auth/logout" and method == "POST":
            return self.v1_logout()
        if path == "/api/v1/devices" and method == "GET":
            return self.v1_list_devices()
        if path == "/api/v1/sync" and method == "GET":
            return self.v1_sync()
        if path == "/api/v1/events" and method == "GET":
            return self.v1_events()
        if path.startswith("/api/v1/devices/"):
            rest = urllib.parse.unquote(path[len("/api/v1/devices/"):])
            if rest.endswith("/heartbeat") and method == "POST":
                return self.v1_heartbeat(rest[:-len("/heartbeat")])
            if method == "PATCH":
                return self.v1_rename_device(rest)
            if method == "DELETE":
                return self.v1_delete_device(rest)
        self.api_fail(404, "not_found", "接口不存在")

    def v1_token(self):
        auth = self.headers.get("authorization", "")
        if auth.startswith("Bearer "):
            return auth[len("Bearer "):].strip()
        if self.headers.get("cookie"):
            jar = cookies.SimpleCookie()
            try:
                jar.load(self.headers.get("cookie"))
            except cookies.CookieError:
                return None
            if "webclip_v1" in jar:
                return jar["webclip_v1"].value
        return None

    def v1_device(self):
        token = self.v1_token()
        if not token:
            return None
        with db() as conn:
            row = conn.execute(
                "select d.*, t.id as token_id from device_tokens t join devices d on d.id = t.device_id "
                "where t.token_hash = ? and t.revoked_at is null and d.enabled = 1",
                (hashlib.sha256(token.encode()).hexdigest(),),
            ).fetchone()
            if not row:
                return None
            conn.execute("update device_tokens set last_used_at=? where id=?", (now_iso(), row["token_id"]))
        return row

    def require_v1_device(self):
        token = self.v1_token()
        if token:
            with db() as conn:
                row = conn.execute(
                    "select revoked_at from device_tokens where token_hash=?",
                    (hashlib.sha256(token.encode()).hexdigest(),),
                ).fetchone()
            if row and row["revoked_at"] is not None:
                self.api_fail(401, "token_revoked", "登录已失效，请重新登录")
        device = self.v1_device()
        if not device:
            self.api_fail(401, "unauthorized", "需要登录")
        return device

    def read_json(self):
        try:
            data = json.loads(self.read_body(1024 * 32).decode())
        except (UnicodeDecodeError, ValueError):
            self.api_fail(400, "bad_json", "请求体不是合法 JSON")
        if not isinstance(data, dict):
            self.api_fail(400, "bad_json", "请求体不是合法 JSON")
        return data

    def v1_login(self):
        ip = client_ip(self)
        now = int(time.time())
        ok = False
        with db() as conn:
            fail = conn.execute("select count, updated_at from login_failures where ip=?", (ip,)).fetchone()
            if fail and fail["count"] >= 8 and now - fail["updated_at"] < 900:
                self.api_fail(429, "login_locked", "尝试次数过多，请稍后再试")
            fields = self.read_json()
            ok = password_ok(str(fields.get("password", "")))
            if ok:
                conn.execute("delete from login_failures where ip=?", (ip,))
                name = str(fields.get("device_name", "")).strip() or "未命名设备"
                platform = str(fields.get("platform", "")).strip() or "web"
                device = conn.execute(
                    "select id from devices where name=? and platform=?", (name, platform)
                ).fetchone()
                if device:
                    device_id = device["id"]
                    conn.execute("update devices set last_seen_at=?, enabled=1 where id=?", (now, device_id))
                else:
                    device_id = secrets.token_hex(8)
                    conn.execute(
                        "insert into devices(id,name,platform,last_seen_at) values(?,?,?,?)",
                        (device_id, name, platform, now),
                    )
                token = issue_device_token(conn, device_id)
                record_change(conn, "device", device_id, "upsert")
            else:
                conn.execute(
                    "insert into login_failures(ip,count,updated_at) values(?,?,?) "
                    "on conflict(ip) do update set count=count+1, updated_at=excluded.updated_at",
                    (ip, 1, now),
                )
        if not ok:
            self.api_fail(401, "invalid_credentials", "密码错误")
        headers = None
        if fields.get("client") == "web" or self.headers.get("x-client") == "web":
            headers = {"Set-Cookie": make_v1_cookie(token)}
        self.send_json({"token": token, "device": {"id": device_id, "name": name, "platform": platform}}, headers=headers)

    def v1_logout(self):
        token = self.v1_token()
        self.require_v1_device()
        with db() as conn:
            conn.execute(
                "update device_tokens set revoked_at=? where token_hash=? and revoked_at is null",
                (now_iso(), hashlib.sha256(token.encode()).hexdigest()),
            )
        self.send_json({"ok": True}, headers={"Set-Cookie": clear_v1_cookie()})

    def v1_list_devices(self):
        self.require_v1_device()
        now = int(time.time())
        with db() as conn:
            rows = conn.execute(
                "select id, name, platform, last_seen_at from devices where enabled=1 order by id"
            ).fetchall()
        devices = []
        for row in rows:
            device = dict(row)
            device["online"] = device["id"] == "web" or now - device["last_seen_at"] < 90
            devices.append(device)
        self.send_json({"devices": devices})

    def v1_rename_device(self, device_id):
        device = self.require_v1_device()
        name = str(self.read_json().get("name", "")).strip()
        if not name:
            self.api_fail(400, "bad_request", "设备名不能为空")
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            target = conn.execute("select id, platform, enabled from devices where id=?", (device_id,)).fetchone()
            if not target:
                self.api_fail(404, "device_not_found", "设备不存在")
            if not target["enabled"]:
                self.api_fail(409, "device_revoked", "设备已撤销")
            conn.execute("update devices set name=? where id=?", (name, device_id))
            record_change(conn, "device", device_id, "upsert")
            result = {"device": {"id": device_id, "name": name, "platform": target["platform"]}}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        self.send_json(result)

    def v1_delete_device(self, device_id):
        device = self.require_v1_device()
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            target = conn.execute("select id, enabled from devices where id=?", (device_id,)).fetchone()
            if not target:
                self.api_fail(404, "device_not_found", "设备不存在")
            if not target["enabled"]:
                self.api_fail(409, "device_revoked", "设备已撤销")
            conn.execute("update devices set enabled=0 where id=?", (device_id,))
            cursor = conn.execute(
                "update device_tokens set revoked_at=? where device_id=? and revoked_at is null",
                (now_iso(), device_id),
            )
            record_change(conn, "device", device_id, "delete")
            result = {"ok": True, "revoked_tokens": cursor.rowcount}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        self.send_json(result)

    def v1_heartbeat(self, device_id):
        device = self.require_v1_device()
        if device["id"] != device_id:
            self.api_fail(403, "device_mismatch", "心跳设备与登录设备不一致")
        idem_key = self.headers.get("idempotency-key", "").strip()
        now = int(time.time())
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            conn.execute("update devices set last_seen_at=? where id=?", (now, device_id))
            record_change(conn, "device", device_id, "upsert")
            result = {"ok": True}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        self.send_json(result)

    def v1_sync(self):
        self.require_v1_device()
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        raw_cursor = query.get("cursor", [""])[0]
        try:
            cursor = int(raw_cursor)
        except ValueError:
            self.api_fail(409, "full_sync_required", "游标无效，请从 cursor=0 全量同步")
        if cursor < 0:
            self.api_fail(409, "full_sync_required", "游标无效，请从 cursor=0 全量同步")
        with db() as conn:
            min_seq = conn.execute("select min(seq) from sync_changes").fetchone()[0]
            if cursor > 0 and min_seq is not None and cursor < min_seq:
                self.api_fail(409, "full_sync_required", "游标早于保留窗口，请从 cursor=0 全量同步")
            rows = conn.execute(
                "select seq, entity, entity_id, op, created_at from sync_changes where seq > ? order by seq",
                (cursor,),
            ).fetchall()
        changes = [dict(row) for row in rows]
        tombstones = [{"entity": row["entity"], "entity_id": row["entity_id"]} for row in rows if row["op"] == "delete"]
        next_cursor = rows[-1]["seq"] if rows else cursor
        self.send_json({"changes": changes, "tombstones": tombstones, "next_cursor": next_cursor})

    def v1_events(self):
        self.require_v1_device()
        version = ITEMS_VERSION
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        try:
            self.wfile.write(f"retry: 2000\nevent: sync\ndata: {version}\n\n".encode())
            self.wfile.flush()
            while True:
                with ITEM_EVENTS:
                    changed = ITEM_EVENTS.wait_for(lambda: ITEMS_VERSION != version, timeout=20)
                    version = ITEMS_VERSION
                message = f"event: sync\ndata: {version}\n\n".encode() if changed else b": keepalive\n\n"
                self.wfile.write(message)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_body(self, limit=MAX_FILE_BYTES + 1024 * 1024):
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError:
            self.fail(400, "bad content length")
        if length < 0:
            self.fail(400, "bad content length")
        if length > limit:
            self.fail(413, "too large")
        return self.rfile.read(length)

    def login(self):
        ip = client_ip(self)
        now = int(time.time())
        with db() as conn:
            fail = conn.execute("select count, updated_at from login_failures where ip=?", (ip,)).fetchone()
            if fail and fail["count"] >= 8 and now - fail["updated_at"] < 900:
                self.fail(429, "too many attempts")
            form = parse_form(self.read_body(1024 * 32), self.headers.get("content-type", ""))
            if str(form.getfirst("username", "")) == USERNAME and password_ok(str(form.getfirst("password", ""))):
                conn.execute("delete from login_failures where ip=?", (ip,))
                version = int(get_setting(conn, "session_version") or "1")
                self.send_response(200)
                self.send_header("Set-Cookie", make_session_cookie(version))
                self.end_headers()
                self.wfile.write(json_bytes({"ok": True}))
                return
            conn.execute(
                "insert into login_failures(ip,count,updated_at) values(?,?,?) on conflict(ip) do update set count=count+1, updated_at=excluded.updated_at",
                (ip, 1, now),
            )
        self.fail(401, "bad login")

    def logout(self):
        self.send_response(200)
        self.send_header("Set-Cookie", clear_session_cookie())
        self.end_headers()
        self.wfile.write(json_bytes({"ok": True}))

    def change_password(self):
        form = parse_form(self.read_body(1024 * 32), self.headers.get("content-type", ""))
        current = str(form.getfirst("current_password", ""))
        new = str(form.getfirst("new_password", ""))
        if not password_ok(current):
            self.fail(401, "bad current password")
        if not strong_enough(new):
            self.fail(400, "new password must be at least 12 chars")
        with db() as conn:
            version = int(get_setting(conn, "session_version") or "1") + 1
            set_setting(conn, "password_hash", hash_password(new))
            set_setting(conn, "session_version", str(version))
            conn.execute("delete from login_failures")
        self.send_response(200)
        self.send_header("Set-Cookie", make_session_cookie(version))
        self.end_headers()
        self.wfile.write(json_bytes({"ok": True}))

    def authed(self):
        jar = cookies.SimpleCookie(self.headers.get("cookie", ""))
        token = jar.get("webclip_session")
        if not token:
            return False
        raw = unsign(token.value)
        if not raw:
            return False
        try:
            user, exp, version, _ = raw.split(":", 3)
            return user == USERNAME and int(exp) > time.time() and int(version) == session_version()
        except ValueError:
            return False

    def require_auth(self):
        if not self.authed():
            self.fail(401, "login required")

    def list_items(self):
        with db() as conn:
            rows = conn.execute("select * from items where web_visible=1 order by created_at desc").fetchall()
        items = []
        for row in rows:
            item = dict(row)
            item.pop("stored_name", None)
            items.append(item)
        self.send_json({"items": items})

    def list_devices(self):
        now = int(time.time())
        with db() as conn:
            conn.execute("update devices set last_seen_at=? where id='web'", (now,))
            rows = conn.execute("select * from devices where enabled=1 and id!='windows' order by case platform when 'mac' then 1 when 'android' then 2 else 3 end").fetchall()
        devices = []
        for row in rows:
            device = dict(row)
            device["online"] = device["id"] == "web" or now - device["last_seen_at"] < 90
            devices.append(device)
        self.send_json({"devices": devices})

    def list_transfers(self, device=""):
        with db() as conn:
            where = "where d.target_device=? and d.status='waiting' and d.source_device!='windows'" if device else "where d.target_device!='windows' and d.source_device!='windows'"
            params = (device,) if device else ()
            rows = conn.execute(
                f"select d.*, i.name, i.kind, i.mime, i.size, i.text, i.expires_at "
                f"from deliveries d join items i on i.id=d.item_id {where} "
                f"order by d.created_at {'asc, d.rowid asc' if device else 'desc, d.rowid desc'} limit 50",
                params,
            ).fetchall()
        transfers = [dict(row) for row in rows]
        if not device:
            seen = set()
            transfers = [row for row in transfers if not ((key := (row["source_device"], row["target_device"], row["kind"], row["name"], row["size"], row["text"] or "")) in seen or seen.add(key))]
        history = []
        if not device:
            with db() as conn:
                history = [
                    dict(row)
                    for row in conn.execute(
                        "select * from transfer_history where created_at >= ? order by created_at desc limit 50",
                        (int(time.time()) - TRANSFER_HISTORY_TTL_SECONDS,),
                    ).fetchall()
                ]
            seen = set()
            history = [row for row in history if not ((key := (row["source_device"], row["target_device"], row["kind"], row["name"], row["size"], row["text"] or "")) in seen or seen.add(key))]
        self.send_json({"transfers": transfers, "history": history})

    def send_download_link(self, item_id):
        with db() as conn:
            exists = conn.execute("select 1 from items where id=?", (item_id,)).fetchone()
        if not exists:
            self.fail(404, "not found")
        self.send_json({"url": signed_download_url(item_id)})

    def stream_events(self):
        version = ITEMS_VERSION
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        try:
            self.wfile.write(b"retry: 2000\n\n")
            self.wfile.flush()
            while True:
                with ITEM_EVENTS:
                    changed = ITEM_EVENTS.wait_for(lambda: ITEMS_VERSION != version, timeout=20)
                    version = ITEMS_VERSION
                message = f"event: items\ndata: {version}\n\n".encode() if changed else b": keepalive\n\n"
                self.wfile.write(message)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_update_manifest(self, platform):
        if platform not in {"mac", "android"}:
            self.send_error(404)
            return
        path = UPDATES_DIR / f"{platform}.json"
        if not path.is_file():
            self.send_error(404)
            return
        self.send(200, path.read_bytes(), "application/json; charset=utf-8")

    def send_update_file(self, name):
        if not name or Path(name).name != name:
            self.send_error(404)
            return
        path = UPDATES_DIR / name
        if not path.is_file():
            self.send_error(404)
            return
        mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(path.stat().st_size))
        self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(name))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with path.open("rb") as source:
            shutil.copyfileobj(source, self.wfile, 64 * 1024)

    def send_probe(self):
        body = json_bytes({"ok": True, "host": self.headers.get("host", ""), "time": int(time.time())})
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def add_text(self):
        body = self.read_body(1024 * 1024)
        form = parse_form(body, self.headers.get("content-type", ""))
        text = str(form.getfirst("text", "")).strip()
        if not text:
            self.fail(400, "empty text")
        item_id = secrets.token_urlsafe(12)
        now = int(time.time())
        source_device = str(form.getfirst("source_device", "web"))[:64] or "web"
        target_device = str(form.getfirst("target_device", "all"))[:64] or "all"
        web_visible = 0 if str(form.getfirst("web_visible", "1")) == "0" else 1
        ttl = form_int(form, "ttl", DRIVE_TTL_SECONDS if (source_device == "web" and target_device == "web") else TRANSFER_TTL_SECONDS, 300, 7 * 86400)
        with db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?)",
                (item_id, "text", "文本", "text/plain; charset=utf-8", len(text.encode()), text, now, now + ttl, source_device, target_device, web_visible),
            )
            delivery_id = create_delivery(conn, item_id, source_device, target_device)
        self.send_json({"ok": True, "id": item_id, "delivery_id": delivery_id})

    def upload(self):
        pinned, temp, disk_used = usage()
        if disk_used >= DISK_HIGH_WATER:
            self.fail(507, "disk high water reached")
        body = self.read_body(MAX_UPLOAD_BYTES)
        form = parse_form(body, self.headers.get("content-type", ""))
        if "files" not in form.fields:
            self.fail(400, "no files")
        fields = form["files"] if isinstance(form["files"], list) else [form["files"]]
        fields = [field for field in fields if getattr(field, "filename", "")]
        if not fields:
            self.fail(400, "no files")
        sizes = [field.file.getbuffer().nbytes for field in fields]
        for field, size in zip(fields, sizes):
            if size > MAX_FILE_BYTES:
                self.fail(413, f"{safe_filename(field.filename)} too large")
        if temp + sum(sizes) > TEMP_LIMIT_BYTES:
            self.fail(507, "temporary storage limit reached")
        saved = []
        source_device = str(form.getfirst("source_device", "web"))[:64] or "web"
        target_device = str(form.getfirst("target_device", "all"))[:64] or "all"
        web_visible = 0 if str(form.getfirst("web_visible", "1")) == "0" else 1
        ttl = form_int(form, "ttl", DRIVE_TTL_SECONDS if (source_device == "web" and target_device == "web") else TRANSFER_TTL_SECONDS, 300, 7 * 86400)
        for field, size in zip(fields, sizes):
            raw_name = safe_filename(field.filename)
            data = field.file.read()
            item_id = secrets.token_urlsafe(12)
            stored = secrets.token_urlsafe(24)
            part = FILES_DIR / f"{stored}.part"
            final = FILES_DIR / stored
            part.write_bytes(data)
            part.replace(final)
            now = int(time.time())
            mime = mimetypes.guess_type(raw_name)[0] or "application/octet-stream"
            with db() as conn:
                conn.execute(
                    "insert into items(id,kind,name,stored_name,mime,size,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?)",
                    (item_id, "image" if mime.startswith("image/") else "file", raw_name, stored, mime, size, now, now + ttl, source_device, target_device, web_visible),
                )
                create_delivery(conn, item_id, source_device, target_device)
            temp += size
            saved.append(item_id)
        if not saved:
            self.fail(400, "no files")
        self.send_json({"ok": True, "ids": saved})

    def send_existing_item(self, item_id):
        form = parse_form(self.read_body(32 * 1024), self.headers.get("content-type", ""))
        target = str(form.getfirst("target_device", "all"))[:64] or "all"
        source = str(form.getfirst("source_device", "web"))[:64] or "web"
        with db() as conn:
            item = conn.execute("select id from items where id=?", (item_id,)).fetchone()
            if not item:
                self.fail(404, "not found")
            delivery_id = create_delivery(conn, item_id, source, target)
        self.send_json({"ok": True, "delivery_id": delivery_id})

    def ack_delivery(self, delivery_id):
        form = parse_form(self.read_body(32 * 1024), self.headers.get("content-type", ""))
        status = str(form.getfirst("status", "delivered"))
        if status not in {"waiting", "delivered", "downloaded", "copied", "failed"}:
            self.fail(400, "bad status")
        with db() as conn:
            delivery = conn.execute("select target_device from deliveries where id=?", (delivery_id,)).fetchone()
            if not delivery:
                self.fail(404, "not found")
            if delivery["target_device"] == "android" and status == "delivered":
                status = "waiting"
            conn.execute("update deliveries set status=?,updated_at=? where id=?", (status, int(time.time()), delivery_id))
        self.send_json({"ok": True, "status": status})

    def heartbeat(self, device_id):
        with db() as conn:
            result = conn.execute("update devices set last_seen_at=? where id=? and enabled=1", (int(time.time()), device_id))
            if not result.rowcount:
                self.fail(404, "device not found")
        self.send_json({"ok": True})

    def toggle_pin(self, item_id):
        with db() as conn:
            item = conn.execute("select pinned,size from items where id=?", (item_id,)).fetchone()
            if not item:
                self.fail(404, "not found")
            pinned, _, _ = usage()
            if not item["pinned"] and pinned + item["size"] > PINNED_LIMIT_BYTES:
                self.fail(507, "pinned storage limit reached")
            expires = None if not item["pinned"] else int(time.time()) + DRIVE_TTL_SECONDS
            conn.execute("update items set pinned=?, expires_at=? where id=?", (0 if item["pinned"] else 1, expires, item_id))
        self.send_json({"ok": True})

    def extend_item(self, item_id):
        with db() as conn:
            item = conn.execute("select pinned from items where id=?", (item_id,)).fetchone()
            if not item:
                self.fail(404, "not found")
            if item["pinned"]:
                self.fail(400, "pinned item does not expire")
            conn.execute("update items set expires_at=max(coalesce(expires_at,0), ?) + ? where id=?", (int(time.time()), 7 * 86400, item_id))
        self.send_json({"ok": True})

    def keep_item(self, item_id):
        now = int(time.time())
        with db() as conn:
            item = conn.execute("select pinned from items where id=?", (item_id,)).fetchone()
            if not item:
                self.fail(404, "not found")
            conn.execute(
                "update items set web_visible=1, expires_at=case when pinned=1 then expires_at else ? end where id=?",
                (now + DRIVE_TTL_SECONDS, item_id),
            )
        self.send_json({"ok": True})

    def update_note(self, item_id):
        form = parse_form(self.read_body(4096), self.headers.get("content-type", ""))
        note = str(form.getfirst("note", "")).strip()
        if len(note) > 200:
            self.fail(400, "note too long")
        with db() as conn:
            result = conn.execute("update items set note=? where id=?", (note, item_id))
            if not result.rowcount:
                self.fail(404, "not found")
        self.send_json({"ok": True, "note": note})

    def delete_item(self, item_id):
        result = delete_items("where id=?", (item_id,))
        if not result["deleted"]:
            self.fail(404, "not found")
        self.send_json({"ok": True, **result})

    def clear_temp(self):
        self.send_json({"ok": True, **delete_items("where pinned=0")})

    def clear_all(self):
        self.send_json({"ok": True, **delete_items("")})

    def download(self, item_id):
        with db() as conn:
            item = conn.execute("select * from items where id=?", (item_id,)).fetchone()
        if not item:
            self.send_error(404)
            return
        if item["kind"] == "text":
            data = item["text"].encode()
            name = "clipboard.txt"
        else:
            path = FILES_DIR / item["stored_name"]
            if not path.exists():
                self.send_error(404)
                return
            name = item["name"]
        self.send_response(200)
        self.send_header("Content-Type", item["mime"])
        self.send_header("Content-Length", str(len(data) if item["kind"] == "text" else path.stat().st_size))
        wants_inline = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("inline") == ["1"]
        disposition = "inline" if wants_inline and item["mime"].startswith("image/") and item["mime"] != "image/svg+xml" else "attachment"
        self.send_header("Content-Disposition", disposition + "; filename*=UTF-8''" + urllib.parse.quote(name))
        self.end_headers()
        if item["kind"] == "text":
            self.wfile.write(data)
        else:
            with path.open("rb") as source:
                shutil.copyfileobj(source, self.wfile, 64 * 1024)

    def send(self, code, body, content_type, headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, data, headers=None, status=200):
        self.send(status, json_bytes(data), "application/json; charset=utf-8", headers)

    def fail(self, code, message):
        self.send(code, json_bytes({"error": message}), "application/json; charset=utf-8")
        raise AbortRequest(message)

    def api_fail(self, status, code, message, details=None):
        err = {"code": code, "message": message}
        if details is not None:
            err["details"] = details
        self.send_json({"error": err}, status=status)
        raise AbortRequest(message)

    def log_message(self, fmt, *args):
        safe_path = html.escape(urllib.parse.urlparse(self.path).path)
        print(f"{self.address_string()} {self.command} {safe_path} {fmt % args}")

    def end_headers(self):
        self.security_headers()
        super().end_headers()

    def security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")


if __name__ == "__main__":
    init()
    if "--cleanup" in sys.argv:
        print(json.dumps(cleanup(include_orphans=True), ensure_ascii=False))
        raise SystemExit(0)
    print(f"Serving on http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
