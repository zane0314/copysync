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
WEB_DIR = Path(os.environ.get("WEBCLIP_WEB_DIR", "web"))
WEB_STATIC_TYPES = {
    "index.html": "text/html; charset=utf-8",
    "app.css": "text/css; charset=utf-8",
    "app.js": "text/javascript; charset=utf-8",
}
HOST = os.environ.get("WEBCLIP_HOST", "127.0.0.1")
PORT = int(os.environ.get("WEBCLIP_PORT", "15080"))
USERNAME = os.environ.get("WEBCLIP_USERNAME", "admin")
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
            ("mac", "Mac端", "mac"),
            ("android", "Android 手机", "android"),
            ("web", "网页临时设备", "web"),
        ):
            conn.execute(
                "insert into devices(id,name,platform,last_seen_at) values(?,?,?,?) on conflict(id) do nothing",
                (device_id, name, platform, now if device_id == "web" else 0),
            )
        conn.execute("update devices set name='Mac端', enabled=1 where id='mac'")
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


def item_json(row):
    return {
        "id": row["id"], "kind": row["kind"], "name": row["name"], "mime": row["mime"],
        "size": row["size"], "text": row["text"], "note": row["note"], "pinned": row["pinned"],
        "created_at": row["created_at"], "expires_at": row["expires_at"],
        "source_device": row["source_device"], "target_device": row["target_device"],
    }


def v1_ttl(raw, default):
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return default
    return max(300, min(7 * 86400, value))


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
                self.serve_go()
            elif path == "/":
                self.serve_static("index.html")
            elif path in ("/app.css", "/app.js"):
                self.serve_static(path.lstrip("/"))
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
        if path == "/api/v1/auth/password" and method == "POST":
            return self.v1_change_password()
        if path == "/api/v1/devices" and method == "GET":
            return self.v1_list_devices()
        if path == "/api/v1/sync" and method == "GET":
            return self.v1_sync()
        if path == "/api/v1/usage" and method == "GET":
            return self.v1_usage()
        if path == "/api/v1/items" and method == "GET":
            return self.v1_list_items()
        if path == "/api/v1/items" and method == "POST":
            return self.v1_create_item()
        if path == "/api/v1/items/clear-temp" and method == "POST":
            return self.v1_clear_temp()
        if path == "/api/v1/items/clear-all" and method == "POST":
            return self.v1_clear_all()
        if path.startswith("/api/v1/items/"):
            rest = urllib.parse.unquote(path[len("/api/v1/items/"):])
            if rest.endswith("/content") and method == "GET":
                return self.v1_item_content(rest[:-len("/content")])
            if rest.endswith("/deliveries") and method == "POST":
                return self.v1_create_delivery(rest[:-len("/deliveries")])
            if "/" not in rest:
                if method == "GET":
                    return self.v1_get_item(rest)
                if method == "PATCH":
                    return self.v1_patch_item(rest)
                if method == "DELETE":
                    return self.v1_delete_item(rest)
        if path == "/api/v1/deliveries" and method == "GET":
            return self.v1_list_deliveries()
        if path.startswith("/api/v1/deliveries/"):
            rest = urllib.parse.unquote(path[len("/api/v1/deliveries/"):])
            if rest.endswith("/ack") and method == "POST":
                return self.v1_ack_delivery(rest[:-len("/ack")])
            if rest.endswith("/cancel") and method == "POST":
                return self.v1_cancel_delivery(rest[:-len("/cancel")])
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

    def v1_change_password(self):
        self.require_v1_device()
        fields = self.read_json()
        current = str(fields.get("current_password", ""))
        new = str(fields.get("new_password", ""))
        if not password_ok(current):
            self.api_fail(401, "invalid_credentials", "当前密码错误")
        if not strong_enough(new):
            self.api_fail(400, "weak_password", "新密码至少 12 个字符")
        with db() as conn:
            version = int(get_setting(conn, "session_version") or "1") + 1
            set_setting(conn, "password_hash", hash_password(new))
            set_setting(conn, "session_version", str(version))
            conn.execute("delete from login_failures")
            # 改密码即全设备下线：所有设备 Token（含当前）立即失效。
            conn.execute("update device_tokens set revoked_at=? where revoked_at is null", (now_iso(),))
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

    def v1_create_item(self):
        device = self.require_v1_device()
        ctype = self.headers.get("content-type", "")
        if ctype.startswith("application/json"):
            return self.v1_create_text_item(device)
        if ctype.startswith("multipart/form-data"):
            return self.v1_create_file_item(device)
        self.api_fail(400, "bad_request", "Content-Type 需为 application/json 或 multipart/form-data")

    def v1_create_text_item(self, device):
        fields = self.read_json()
        if fields.get("kind", "text") != "text":
            self.api_fail(400, "unsupported_kind", "JSON 创建仅支持文本")
        text = str(fields.get("text", "")).strip()
        if not text:
            self.api_fail(400, "empty_text", "文本不能为空")
        note = str(fields.get("note", ""))
        target_device = str(fields.get("target_device", ""))[:64]
        ttl = v1_ttl(fields.get("ttl"), TRANSFER_TTL_SECONDS if target_device and target_device != "web" else DRIVE_TTL_SECONDS)
        idem_key = self.headers.get("idempotency-key", "").strip()
        item_id = secrets.token_urlsafe(12)
        now = int(time.time())
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,note,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?,?)",
                (item_id, "text", "文本", "text/plain; charset=utf-8", len(text.encode()), text, note,
                 now, now + ttl, device["id"], target_device or "all", 1),
            )
            if target_device:
                create_delivery(conn, item_id, device["id"], target_device)
            record_change(conn, "item", item_id, "upsert")
            result = {"item": item_json(conn.execute("select * from items where id=?", (item_id,)).fetchone())}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        notify_items_changed()
        self.send_json(result)

    def v1_create_file_item(self, device):
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError:
            self.api_fail(400, "bad_request", "bad content length")
        if length > MAX_UPLOAD_BYTES:
            self.api_fail(413, "file_too_large", "请求体超过上传上限")
        form = parse_form(self.read_body(MAX_UPLOAD_BYTES), self.headers.get("content-type", ""))
        field = form.fields.get("file")
        if isinstance(field, list):
            field = field[0]
        if not field or not field.filename:
            self.api_fail(400, "no_file", "缺少文件字段 file")
        raw_name = safe_filename(field.filename)
        data = field.file.read()
        size = len(data)
        if size > MAX_FILE_BYTES:
            self.api_fail(413, "file_too_large", f"{raw_name} 超过单文件上限")
        pinned, temp, disk_used = usage()
        if disk_used >= DISK_HIGH_WATER:
            self.api_fail(507, "storage_full", "磁盘水位过高")
        if temp + size > TEMP_LIMIT_BYTES:
            self.api_fail(507, "temp_storage_full", "临时存储已达上限")
        note = str(form.getfirst("note", ""))
        target_device = str(form.getfirst("target_device", ""))[:64]
        ttl = v1_ttl(form.getfirst("ttl", ""), TRANSFER_TTL_SECONDS if target_device and target_device != "web" else DRIVE_TTL_SECONDS)
        idem_key = self.headers.get("idempotency-key", "").strip()
        mime = mimetypes.guess_type(raw_name)[0] or "application/octet-stream"
        kind = "image" if mime.startswith("image/") else "file"
        variant_field = form.fields.get("clipboard_variant")
        if isinstance(variant_field, list):
            variant_field = variant_field[0]
        variant_data = variant_mime = None
        if variant_field and variant_field.filename:
            if kind != "image":
                self.api_fail(400, "unsupported_variant_type", "clipboard 变体仅用于图片项目")
            variant_data = variant_field.file.read()
            variant_mime = mimetypes.guess_type(safe_filename(variant_field.filename))[0] or "application/octet-stream"
            if variant_mime not in ("image/png", "image/jpeg", "image/webp", "image/gif", "image/heic"):
                self.api_fail(400, "unsupported_variant_type", "clipboard 变体仅支持 PNG/JPEG/WebP/GIF/HEIC")
            if len(variant_data) > MAX_FILE_BYTES:
                self.api_fail(413, "file_too_large", "clipboard 变体超过单文件上限")
            declared = form.getfirst("clipboard_sha256", "").strip().lower()
            if declared and declared != hashlib.sha256(variant_data).hexdigest():
                self.api_fail(400, "sha256_mismatch", "clipboard 变体 SHA-256 与声明不一致")
        item_id = secrets.token_urlsafe(12)
        stored = secrets.token_urlsafe(24)
        variant_stored = secrets.token_urlsafe(24) if variant_data is not None else None
        now = int(time.time())
        try:
            with db() as conn:
                if idem_key:
                    cached = idem_replay(conn, device["id"], idem_key)
                    if cached is not None:
                        self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                        return
                part = FILES_DIR / f"{stored}.part"
                part.write_bytes(data)
                digest = sha256_file(part)
                part.replace(FILES_DIR / stored)
                if variant_data is not None:
                    vpart = FILES_DIR / f"{variant_stored}.part"
                    vpart.write_bytes(variant_data)
                    vdigest = sha256_file(vpart)
                    vpart.replace(FILES_DIR / variant_stored)
                conn.execute(
                    "insert into items(id,kind,name,stored_name,mime,size,note,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?,?)",
                    (item_id, kind, raw_name, stored, mime, size, note, now, now + ttl, device["id"], target_device or "all", 1),
                )
                conn.execute(
                    "insert into item_blobs(item_id, variant, stored_name, mime, size, sha256, created_at) values(?,?,?,?,?,?,?)",
                    (item_id, "original", stored, mime, size, digest, now_iso()),
                )
                if variant_data is not None:
                    conn.execute(
                        "insert into item_blobs(item_id, variant, stored_name, mime, size, sha256, created_at) values(?,?,?,?,?,?,?)",
                        (item_id, "clipboard", variant_stored, variant_mime, len(variant_data), vdigest, now_iso()),
                    )
                if target_device:
                    create_delivery(conn, item_id, device["id"], target_device)
                record_change(conn, "item", item_id, "upsert")
                result = {"item": item_json(conn.execute("select * from items where id=?", (item_id,)).fetchone())}
                if idem_key:
                    idem_store(conn, device["id"], idem_key, result)
        except Exception:
            unlink_file(stored)
            if variant_stored:
                unlink_file(variant_stored)
            raise
        notify_items_changed()
        self.send_json(result)

    def v1_item_content(self, item_id):
        self.require_v1_device()
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        variant = query.get("variant", ["original"])[0]
        if variant not in ("original", "clipboard"):
            self.api_fail(400, "bad_variant", "variant 仅支持 original 或 clipboard")
        with db() as conn:
            item = conn.execute("select * from items where id=?", (item_id,)).fetchone()
            if not item:
                self.api_fail(404, "item_not_found", "项目不存在")
            blob = conn.execute(
                "select * from item_blobs where item_id=? and variant=?", (item_id, variant)
            ).fetchone()
        if item["kind"] == "text" and variant == "original":
            data = item["text"].encode()
            return self.send_blob(item["mime"], "clipboard.txt", data=data)
        if not blob and variant == "original" and item["stored_name"]:
            blob = {"stored_name": item["stored_name"], "mime": item["mime"]}  # 旧路由创建的项目没有 blob 行
        if not blob:
            if variant == "clipboard":
                self.api_fail(404, "variant_missing", "该图片没有 clipboard 变体（应为 PNG/JPEG/WebP/GIF/HEIC 首帧）")
            self.api_fail(404, "variant_missing", "该项目的 original 内容不存在")
        path = FILES_DIR / blob["stored_name"]
        if not path.exists():
            self.api_fail(404, "content_missing", "文件已丢失")
        if variant == "clipboard":
            ext = mimetypes.guess_extension(blob["mime"]) or ""
            name = Path(item["name"]).stem + ".clipboard" + ext
        else:
            name = item["name"]
        self.send_blob(blob["mime"], name, path=path)

    def v1_list_items(self):
        self.require_v1_device()
        with db() as conn:
            rows = conn.execute("select * from items where web_visible=1 order by created_at desc").fetchall()
        self.send_json({"items": [item_json(row) for row in rows]})

    def v1_get_item(self, item_id):
        self.require_v1_device()
        with db() as conn:
            item = conn.execute("select * from items where id=?", (item_id,)).fetchone()
        if not item:
            self.api_fail(404, "item_not_found", "项目不存在")
        self.send_json({"item": item_json(item)})

    def v1_usage(self):
        self.require_v1_device()
        pinned, temp, disk_used = usage()
        self.send_json({
            "temp_bytes": temp,
            "pinned_bytes": pinned,
            "total_bytes": pinned + temp,
            "limits": {"pinned": PINNED_LIMIT_BYTES, "temp": TEMP_LIMIT_BYTES, "max_file": MAX_FILE_BYTES},
        })

    def v1_patch_item(self, item_id):
        device = self.require_v1_device()
        fields = self.read_json()
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            item = conn.execute("select * from items where id=?", (item_id,)).fetchone()
            if not item:
                self.api_fail(404, "item_not_found", "项目不存在")
            now = int(time.time())
            if "pinned" in fields:
                pin = 1 if fields["pinned"] else 0
                if pin and not item["pinned"]:
                    pinned, _, _ = usage()
                    if pinned + item["size"] > PINNED_LIMIT_BYTES:
                        self.api_fail(409, "pinned_limit", "图钉存储已达上限")
                conn.execute("update items set pinned=? where id=?", (pin, item_id))
                if pin:
                    conn.execute("update items set expires_at=null where id=?", (item_id,))
                elif "expires_at" not in fields and "ttl" not in fields:
                    conn.execute("update items set expires_at=? where id=?", (now + DRIVE_TTL_SECONDS, item_id))
            if "note" in fields:
                note = str(fields["note"]).strip()
                if len(note) > 200:
                    self.api_fail(400, "note_too_long", "备注过长")
                conn.execute("update items set note=? where id=?", (note, item_id))
            if "expires_at" in fields:
                value = fields["expires_at"]
                if value is not None:
                    try:
                        value = int(value)
                    except (TypeError, ValueError):
                        self.api_fail(400, "bad_request", "expires_at 需为整数或 null")
                conn.execute("update items set expires_at=? where id=?", (value, item_id))
            elif "ttl" in fields:
                ttl = v1_ttl(fields["ttl"], DRIVE_TTL_SECONDS)
                conn.execute("update items set expires_at=? where id=?", (now + ttl, item_id))
            record_change(conn, "item", item_id, "upsert")
            result = {"item": item_json(conn.execute("select * from items where id=?", (item_id,)).fetchone())}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        notify_items_changed()
        self.send_json(result)

    def v1_clear_temp(self):
        self._v1_clear_items("where pinned=0")

    def v1_clear_all(self):
        self._v1_clear_items("")

    def _v1_clear_items(self, where):
        device = self.require_v1_device()
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            rows = conn.execute("select id, stored_name, size from items " + where).fetchall()
            blobs = conn.execute(
                "select item_id, stored_name from item_blobs where item_id in (select id from items " + where + ")"
            ).fetchall()
            files = []
            seen = set()
            for stored in [r["stored_name"] for r in rows] + [r["stored_name"] for r in blobs]:
                if stored and stored not in seen:
                    seen.add(stored)
                    files.append(stored)
            freed = sum(r["size"] for r in rows if not r["stored_name"])
            for stored in files:
                try:
                    freed += (FILES_DIR / stored).stat().st_size
                except FileNotFoundError:
                    pass
            conn.execute("delete from item_blobs where item_id in (select id from items " + where + ")")
            conn.execute("delete from items " + where)
            for row in rows:
                record_change(conn, "item", row["id"], "delete")
            result = {"ok": True, "deleted": len(rows), "bytes": freed}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        for stored in files:  # 事务提交后删文件；残留由 cleanup 兜底
            unlink_file(stored)
        notify_items_changed()
        self.send_json(result)

    def v1_delete_item(self, item_id):
        device = self.require_v1_device()
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            item = conn.execute("select id, stored_name from items where id=?", (item_id,)).fetchone()
            if not item:
                self.api_fail(404, "item_not_found", "项目不存在")
            files = [row[0] for row in conn.execute("select stored_name from item_blobs where item_id=?", (item_id,))]
            if item["stored_name"] and item["stored_name"] not in files:
                files.append(item["stored_name"])
            conn.execute("delete from item_blobs where item_id=?", (item_id,))
            conn.execute("delete from items where id=?", (item_id,))
            record_change(conn, "item", item_id, "delete")
            result = {"ok": True, "id": item_id}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        for stored in files:  # 事务提交后删文件；残留由 cleanup 兜底
            unlink_file(stored)
        notify_items_changed()
        self.send_json(result)

    def v1_create_delivery(self, item_id):
        device = self.require_v1_device()
        fields = self.read_json()
        target = str(fields.get("target_device", ""))[:64]
        if not target:
            self.api_fail(400, "bad_request", "缺少 target_device")
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            if not conn.execute("select id from items where id=?", (item_id,)).fetchone():
                self.api_fail(404, "item_not_found", "项目不存在")
            target_row = conn.execute("select id, enabled from devices where id=?", (target,)).fetchone()
            if not target_row:
                self.api_fail(404, "device_not_found", "目标设备不存在")
            if not target_row["enabled"]:
                self.api_fail(409, "device_revoked", "目标设备已撤销")
            delivery_id = create_delivery(conn, item_id, device["id"], target)
            record_change(conn, "delivery", delivery_id, "upsert")
            row = conn.execute("select * from deliveries where id=?", (delivery_id,)).fetchone()
            result = {"delivery": dict(row)}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        notify_items_changed()
        self.send_json(result)

    def v1_list_deliveries(self):
        self.require_v1_device()
        with db() as conn:
            rows = conn.execute(
                "select d.id, d.item_id, d.source_device, d.target_device, d.status, d.created_at, d.updated_at, "
                "i.kind, i.name, i.mime, i.size, i.text, i.expires_at "
                "from deliveries d join items i on i.id=d.item_id "
                "where d.target_device!='windows' and d.source_device!='windows' "
                "order by d.created_at desc, d.rowid desc limit 50"
            ).fetchall()
            history = [
                dict(row)
                for row in conn.execute(
                    "select * from transfer_history where created_at >= ? order by created_at desc limit 50",
                    (int(time.time()) - TRANSFER_HISTORY_TTL_SECONDS,),
                ).fetchall()
            ]
        deliveries = [dict(row) for row in rows]
        seen = set()
        deliveries = [row for row in deliveries if not ((key := (row["source_device"], row["target_device"], row["kind"], row["name"], row["size"], row["text"] or "")) in seen or seen.add(key))]
        seen = set()
        history = [row for row in history if not ((key := (row["source_device"], row["target_device"], row["kind"], row["name"], row["size"], row["text"] or "")) in seen or seen.add(key))]
        self.send_json({"deliveries": deliveries, "history": history})

    def v1_ack_delivery(self, delivery_id):
        device = self.require_v1_device()
        status = str(self.read_json().get("status", "delivered"))
        if status not in {"waiting", "delivered", "downloaded", "copied", "failed"}:
            self.api_fail(400, "bad_request", "非法状态")
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            delivery = conn.execute("select * from deliveries where id=?", (delivery_id,)).fetchone()
            if not delivery:
                self.api_fail(404, "delivery_not_found", "投递不存在")
            if delivery["target_device"] != device["id"]:
                self.api_fail(403, "device_mismatch", "只能由目标设备确认")
            target = conn.execute("select platform from devices where id=?", (delivery["target_device"],)).fetchone()
            if target and target["platform"] == "android" and status == "delivered":
                status = "waiting"  # android 需手动接收，delivered 降级为 waiting
            conn.execute("update deliveries set status=?, updated_at=? where id=?", (status, int(time.time()), delivery_id))
            record_change(conn, "delivery", delivery_id, "upsert")
            row = conn.execute("select * from deliveries where id=?", (delivery_id,)).fetchone()
            result = {"delivery": dict(row)}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        notify_items_changed()
        self.send_json(result)

    def v1_cancel_delivery(self, delivery_id):
        # 发送方撤回自己发出、对方还没接收的等待项（收件箱「全部已读」清理出站项用）。
        # 只允许 source_device==本机 撤回；置为 cancelled 后会从对方待接收队列消失并被归档。
        device = self.require_v1_device()
        idem_key = self.headers.get("idempotency-key", "").strip()
        with db() as conn:
            if idem_key:
                cached = idem_replay(conn, device["id"], idem_key)
                if cached is not None:
                    self.send_json(cached, headers={"X-Idempotent-Replay": "1"})
                    return
            delivery = conn.execute("select * from deliveries where id=?", (delivery_id,)).fetchone()
            if not delivery:
                self.api_fail(404, "delivery_not_found", "投递不存在")
            if delivery["source_device"] != device["id"]:
                self.api_fail(403, "device_mismatch", "只能由发送方撤回")
            conn.execute("update deliveries set status=?, updated_at=? where id=?", ("cancelled", int(time.time()), delivery_id))
            record_change(conn, "delivery", delivery_id, "upsert")
            row = conn.execute("select * from deliveries where id=?", (delivery_id,)).fetchone()
            result = {"delivery": dict(row)}
            if idem_key:
                idem_store(conn, device["id"], idem_key, result)
        notify_items_changed()
        self.send_json(result)

    def send_blob(self, mime, name, data=None, path=None):
        wants_inline = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("inline") == ["1"]
        disposition = "inline" if wants_inline and mime.startswith("image/") and mime != "image/svg+xml" else "attachment"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data) if data is not None else path.stat().st_size))
        self.send_header("Content-Disposition", disposition + "; filename*=UTF-8''" + urllib.parse.quote(name))
        self.end_headers()
        if data is not None:
            self.wfile.write(data)
        else:
            with path.open("rb") as source:
                shutil.copyfileobj(source, self.wfile, 64 * 1024)

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
            # 改密码即全设备下线：v1 设备 Token 一并撤销。
            conn.execute("update device_tokens set revoked_at=? where revoked_at is null", (now_iso(),))
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

    def serve_static(self, name):
        content_type = WEB_STATIC_TYPES.get(name)
        path = WEB_DIR / name if content_type else None
        if not content_type or not path.is_file():
            self.send_error(404)
            return
        # 静态资源统一 no-store：内网小体量，避免更新后浏览器缓存旧版本
        self.send(200, path.read_bytes(), content_type)

    def serve_go(self):
        path = WEB_DIR / "go.html"
        if not path.is_file():
            self.send_error(404)
            return
        page = path.read_text(encoding="utf-8").replace("__DIRECT_URL__", DIRECT_URL).replace("__CF_URL__", CF_URL)
        self.send(200, page.encode(), "text/html; charset=utf-8")

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
