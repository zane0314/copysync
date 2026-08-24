import hashlib
import http.client
import json
import os
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer


tmp = tempfile.TemporaryDirectory()
os.environ.update(
    WEBCLIP_DATA_DIR=tmp.name,
    WEBCLIP_PASSWORD="review-password-123",
    WEBCLIP_SESSION_SECRET="review-session-secret-123",
    WEBCLIP_COOKIE_SECURE="0",
)

import app

PW = "review-password-123"  # 与上方 WEBCLIP_PASSWORD 一致


class WebClipboardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.init()

    def test_password_signature_and_cleanup_preserve_pin(self):
        self.assertTrue(app.password_ok("review-password-123"))
        self.assertEqual(app.unsign(app.sign("value")), "value")
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,pinned,created_at,expires_at) values(?,?,?,?,?,?,?,?,?)",
                ("temp", "text", "文本", "text/plain", 1, "a", 0, now, now - 1),
            )
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,pinned,created_at,expires_at) values(?,?,?,?,?,?,?,?,?)",
                ("pin", "text", "文本", "text/plain", 1, "b", 1, now, None),
            )
        app.cleanup()
        with app.db() as conn:
            self.assertEqual([row[0] for row in conn.execute("select id from items")], ["pin"])

    def test_every_card_has_copy_download_refresh_and_event_sync(self):
        page = app.index_html().decode()
        self.assertIn('data-copy="${i.id}">复制</button>', page)
        self.assertIn('data-download="${i.id}" href="/download/${i.id}" download>下载</a>', page)
        self.assertIn('id="refreshBtn">刷新</button>', page)
        self.assertIn('<title>CopySync</title>', page)
        self.assertIn('href="/favicon.png"', page)
        self.assertIn("new EventSource('/api/events')", page)
        self.assertNotIn('setInterval(', page)
        self.assertIn("new ClipboardItem({'image/png': png})", page)
        self.assertIn('class="workspace"', page)
        self.assertIn('class="panel drive"', page)
        self.assertIn('class="panel transfer"', page)
        self.assertIn('id="syncWeb"', page)
        self.assertIn('id="targetDevice"', page)
        self.assertIn("const IS_ANDROID_APP", page)
        self.assertIn('class="android-quick"', page)
        self.assertIn('粘贴文本', page)
        self.assertIn('选文件', page)
        self.assertIn('选照片', page)
        self.assertIn('data-receive="${t.id}"', page)
        self.assertIn('async function receiveTransfer(deliveryId)', page)
        self.assertIn("type:'revealReceived'", page)
        self.assertIn('CopySyncNative.receiveFile(transfer.id, transfer.item_id', page)
        self.assertIn('CopySyncNative.revealReceived(transfer.id, transfer.item_id', page)
        self.assertIn("CopySyncNative.saveSent", page)
        self.assertIn("CopySyncNative.localFileState", page)
        self.assertIn("function copySyncLocalFileReady", page)
        self.assertIn("已在文件管理器中定位已发送文件", page)
        self.assertIn("文件正在接收，请稍候", page)
        self.assertIn("本地文件已删除，正在重新接收", page)
        self.assertIn("type:'saveSent'", page)
        self.assertIn("copyLink.textContent = '复制下载链接'", page)
        self.assertIn("await copyDownloadLink(transfer.item_id)", page)
        self.assertIn("type:'copyText'", page)
        self.assertIn("CopySyncNative.copyText", page)
        self.assertIn("window.__copyDownloadUrl = link", page)
        self.assertIn("'/api/items/' + encodeURIComponent(itemId) + '/link'", page)
        self.assertNotIn("MacBook", page)
        self.assertNotIn("Windows", page)
        self.assertIn("showGlassToast('下载链接已复制')", page)
        self.assertIn("toast.classList.remove('show'), 3000", page)
        self.assertIn('id="androidInboxList"', page)
        self.assertIn('id="androidDrive"', page)
        self.assertIn('id="androidRecords"', page)
        self.assertIn("传输记录", page)
        self.assertIn('data-receive="${t.id}"', page)
        self.assertIn("fileMsg.textContent = '已开始下载 '", page)
        self.assertIn('@media (max-width:900px)', page)
        self.assertIn('location.replace(usable[0].url)', page)
        self.assertNotIn('但仍由你手动选择', page)

    def test_note_column_exists(self):
        with app.db() as conn:
            columns = {row["name"] for row in conn.execute("pragma table_info(items)")}
        self.assertIn("note", columns)
        self.assertTrue({"source_device", "target_device", "web_visible"}.issubset(columns))

    def test_delivery_can_target_device_without_web_copy(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?)",
                ("device-only", "text", "文本", "text/plain", 5, "hello", now, now + 300, "web", "android", 0),
            )
            delivery_id = app.create_delivery(conn, "device-only", "web", "android")
            row = conn.execute("select * from deliveries where id=?", (delivery_id,)).fetchone()
        self.assertEqual(row["status"], "waiting")
        self.assertEqual(row["target_device"], "android")
        with app.db() as conn:
            conn.execute("delete from items where id='device-only'")

    def test_offline_delivery_survives_expiry_until_acknowledged(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?)",
                ("offline", "text", "文本", "text/plain", 7, "queued", now, now - 1, "mac", "android", 0),
            )
            delivery_id = app.create_delivery(conn, "offline", "mac", "android")
        app.cleanup()
        with app.db() as conn:
            self.assertIsNotNone(conn.execute("select id from items where id='offline'").fetchone())
            conn.execute("update deliveries set status='delivered' where id=?", (delivery_id,))
        app.cleanup()
        with app.db() as conn:
            self.assertIsNone(conn.execute("select id from items where id='offline'").fetchone())

    def test_all_devices_creates_independent_offline_deliveries(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?)",
                ("fanout", "text", "文本", "text/plain", 3, "all", now, now + 300, "mac", "all", 1),
            )
            app.create_delivery(conn, "fanout", "mac", "all")
            rows = conn.execute("select target_device,status from deliveries where item_id='fanout' order by target_device").fetchall()
        self.assertEqual([(row["target_device"], row["status"]) for row in rows], [("android", "waiting")])
        with app.db() as conn:
            conn.execute("delete from items where id='fanout'")

    def test_device_inbox_returns_only_pending_oldest_first(self):
        now = int(time.time())
        with app.db() as conn:
            for item_id, created in (("pending-old", now - 2), ("pending-new", now - 1), ("done", now)):
                conn.execute(
                    "insert into items(id,kind,name,mime,size,text,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?,?)",
                    (item_id, "text", "文本", "text/plain", 1, item_id, created, now + 300, "mac", "android", 0),
                )
                delivery_id = app.create_delivery(conn, item_id, "mac", "android")
                if item_id == "done":
                    conn.execute("update deliveries set status='delivered' where id=?", (delivery_id,))
        result = {}
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: result.update(payload)
        handler.list_transfers("android")
        self.assertEqual([row["item_id"] for row in result["transfers"]], ["pending-old", "pending-new"])
        with app.db() as conn:
            conn.execute("delete from items where id in ('pending-old','pending-new','done')")

    def test_android_delivered_ack_stays_waiting_until_manual_receive(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?)",
                ("android-manual", "file", "manual.js", "text/javascript", 10, now, now + 300, "mac", "android", 0),
            )
            delivery_id = app.create_delivery(conn, "android-manual", "mac", "android")
        handler = object.__new__(app.Handler)
        handler.read_body = lambda limit: b"status=delivered"
        handler.headers = {"content-type": "application/x-www-form-urlencoded"}
        result = {}
        handler.send_json = lambda payload: result.update(payload)
        handler.ack_delivery(delivery_id)
        with app.db() as conn:
            status = conn.execute("select status from deliveries where id=?", (delivery_id,)).fetchone()[0]
            conn.execute("delete from items where id='android-manual'")
        self.assertEqual(status, "waiting")
        self.assertEqual(result["status"], "waiting")

    def test_recent_transfers_collapses_duplicate_content_into_one_card(self):
        now = int(time.time())
        with app.db() as conn:
            for item_id, status in (("duplicate-a", "delivered"), ("duplicate-b", "downloaded")):
                conn.execute(
                    "insert into items(id,kind,name,mime,size,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?)",
                    (item_id, "file", "same.zip", "application/zip", 42, now, now + 300, "android", "mac", 0),
                )
                delivery_id = app.create_delivery(conn, item_id, "android", "mac")
                conn.execute("update deliveries set status=? where id=?", (status, delivery_id))
        result = {}
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: result.update(payload)
        handler.list_transfers()
        duplicates = [row for row in result["transfers"] if row["name"] == "same.zip"]
        self.assertEqual(len(duplicates), 1)
        with app.db() as conn:
            conn.execute("delete from items where id in ('duplicate-a','duplicate-b')")

    def test_invalid_ttl_uses_safe_default(self):
        form = app.parse_form(b"ttl=not-a-number", "application/x-www-form-urlencoded")
        self.assertEqual(app.form_int(form, "ttl", 14400, 300, 604800), 14400)

    def test_update_paths_reject_traversal(self):
        handler = object.__new__(app.Handler)
        result = {}
        handler.send_error = lambda code: result.update(code=code)
        handler.send_update_file("../secret")
        self.assertEqual(result["code"], 404)

    def test_login_cookie_persists_for_30_days(self):
        cookie = app.make_session_cookie()
        self.assertIn("Max-Age=2592000", cookie)
        self.assertIn("expires=", cookie)
        old_domain = app.COOKIE_DOMAIN
        try:
            app.COOKIE_DOMAIN = ".example.com"
            self.assertIn("Domain=.example.com", app.make_session_cookie())
        finally:
            app.COOKIE_DOMAIN = old_domain

    def test_signed_download_link_is_item_bound_and_public(self):
        item_id = "signed-file"
        token = app.sign("download:" + item_id)
        self.assertTrue(app.download_token_valid(item_id, token))
        self.assertFalse(app.download_token_valid("another-file", token))
        url = app.signed_download_url(item_id)
        parsed = app.urllib.parse.urlparse(url)
        self.assertEqual(parsed.path, "/download/" + item_id)
        self.assertTrue(app.download_token_valid(item_id, app.urllib.parse.parse_qs(parsed.query)["token"][0]))

    def test_download_link_api_requires_an_existing_item(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,created_at,expires_at) values(?,?,?,?,?,?,?,?)",
                ("link-item", "text", "文本", "text/plain", 4, "link", now, now + 300),
            )
        result = {}
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: result.update(payload)
        handler.send_download_link("link-item")
        self.assertIn("?token=", result["url"])
        with app.db() as conn:
            conn.execute("delete from items where id='link-item'")

    def test_windows_device_is_removed_and_mac_is_renamed(self):
        with app.db() as conn:
            devices = {row["id"]: row for row in conn.execute("select id,name,enabled from devices")}
        self.assertEqual(devices["mac"]["name"], "Mac")
        self.assertNotIn("windows", devices)

    def test_urlencoded_form_accepts_text(self):
        form = app.parse_form(b"text=hello+world", "application/x-www-form-urlencoded")
        self.assertEqual(form.getfirst("text"), "hello world")

    def test_pinning_does_not_change_time_order(self):
        with app.db() as conn:
            conn.execute("delete from items")
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,pinned,created_at,expires_at) values(?,?,?,?,?,?,?,?,?)",
                ("old-pin", "text", "文本", "text/plain", 1, "old", 1, 100, None),
            )
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,pinned,created_at,expires_at) values(?,?,?,?,?,?,?,?,?)",
                ("new", "text", "文本", "text/plain", 1, "new", 0, 200, 9999999999),
            )
        result = {}
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: result.update(payload)
        handler.list_items()
        self.assertEqual([item["id"] for item in result["items"]], ["new", "old-pin"])

    def test_extend_renews_seven_days_from_expiry(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,pinned,created_at,expires_at) values(?,?,?,?,?,?,?,?,?)",
                ("renew-me", "text", "文本", "text/plain", 1, "r", 0, now, now + 3600),
            )
        result = {}
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: result.update(payload)
        handler.extend_item("renew-me")
        with app.db() as conn:
            expires = conn.execute("select expires_at from items where id='renew-me'").fetchone()[0]
            conn.execute("delete from items where id='renew-me'")
        self.assertEqual(expires, now + 3600 + 7 * 86400)
        self.assertTrue(result["ok"])

    def test_extend_from_past_expiry_starts_from_now(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,text,pinned,created_at,expires_at) values(?,?,?,?,?,?,?,?,?)",
                ("renew-past", "text", "文本", "text/plain", 1, "r", 0, now, now + 10),
            )
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: None
        handler.extend_item("renew-past")
        with app.db() as conn:
            expires = conn.execute("select expires_at from items where id='renew-past'").fetchone()[0]
            conn.execute("delete from items where id='renew-past'")
        self.assertGreaterEqual(expires, now + 7 * 86400)

    def test_keep_moves_transfer_item_to_drive_with_seven_days(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?)",
                ("keep-me", "file", "doc.pdf", "application/pdf", 10, now, now + 300, "mac", "android", 0),
            )
        handler = object.__new__(app.Handler)
        handler.send_json = lambda payload: None
        handler.keep_item("keep-me")
        with app.db() as conn:
            row = conn.execute("select web_visible, expires_at from items where id='keep-me'").fetchone()
            conn.execute("delete from items where id='keep-me'")
        self.assertEqual(row["web_visible"], 1)
        self.assertGreaterEqual(row["expires_at"], now + 7 * 86400)

    def test_expired_item_leaves_history_record_for_thirty_days(self):
        now = int(time.time())
        with app.db() as conn:
            conn.execute(
                "insert into items(id,kind,name,mime,size,created_at,expires_at,source_device,target_device,web_visible) values(?,?,?,?,?,?,?,?,?,?)",
                ("history-me", "file", "old.zip", "application/zip", 42, now - 100, now - 1, "mac", "android", 0),
            )
            delivery_id = app.create_delivery(conn, "history-me", "mac", "android")
            conn.execute("update deliveries set status='downloaded' where id=?", (delivery_id,))
        app.cleanup()
        with app.db() as conn:
            self.assertIsNone(conn.execute("select id from items where id='history-me'").fetchone())
            record = conn.execute("select * from transfer_history where id=?", (delivery_id,)).fetchone()
        self.assertIsNotNone(record)
        self.assertEqual(record["name"], "old.zip")
        self.assertEqual(record["status"], "downloaded")
        with app.db() as conn:
            conn.execute("update transfer_history set created_at=? where id=?", (now - 31 * 86400, delivery_id))
        app.cleanup()
        with app.db() as conn:
            self.assertIsNone(conn.execute("select id from transfer_history where id=?", (delivery_id,)).fetchone())

    def test_default_ttl_seven_days_for_drive_one_day_for_transfer(self):
        handler = object.__new__(app.Handler)
        handler.headers = {"content-type": "application/x-www-form-urlencoded"}
        result = {}
        handler.send_json = lambda payload: result.update(payload)
        handler.read_body = lambda limit: b"text=drive-note&source_device=web&target_device=web"
        handler.add_text()
        handler.read_body = lambda limit: b"text=transfer-note&source_device=web&target_device=android"
        handler.add_text()
        now = int(time.time())
        with app.db() as conn:
            rows = {
                row["text"]: row["expires_at"] - row["created_at"]
                for row in conn.execute("select text, created_at, expires_at from items where text in ('drive-note','transfer-note')")
            }
            conn.execute("delete from items where text in ('drive-note','transfer-note')")
        self.assertEqual(rows["drive-note"], 7 * 86400)
        self.assertEqual(rows["transfer-note"], 86400)


class QuietHandler(app.Handler):
    def log_message(self, *args):
        pass


class V1Case(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.init()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.old_high_water = app.DISK_HIGH_WATER
        app.DISK_HIGH_WATER = 1.0  # 测试不依赖宿主机真实磁盘水位

    def tearDown(self):
        app.DISK_HIGH_WATER = self.old_high_water
        with app.db() as conn:
            rows = conn.execute(
                "select stored_name from items where source_device not in ('mac','android','web')"
            ).fetchall()
            conn.execute("delete from item_blobs where item_id in (select id from items where source_device not in ('mac','android','web'))")
            conn.execute("delete from items where source_device not in ('mac','android','web')")
            conn.execute("delete from device_tokens where device_id not in ('mac','android','web')")
            conn.execute("delete from devices where id not in ('mac','android','web')")
            conn.execute("delete from sync_changes")
            conn.execute("delete from idempotency_keys")
            conn.execute("delete from login_failures")
        for row in rows:
            if row["stored_name"]:
                try:
                    (app.FILES_DIR / row["stored_name"]).unlink()
                except FileNotFoundError:
                    pass

    def multipart_body(self, boundary, parts):
        out = b""
        for name, filename, ctype, data in parts:
            out += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'.encode()
            if filename is not None:
                out += f'; filename="{filename}"\r\nContent-Type: {ctype}'.encode()
            out += b"\r\n\r\n" + data + b"\r\n"
        return out + f"--{boundary}--\r\n".encode()

    def raw_request_full(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        payload = None
        merged = dict(headers or {})
        if body is not None:
            if isinstance(body, (bytes, bytearray)):
                payload = bytes(body)
            else:
                payload = json.dumps(body).encode()
                merged.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=payload, headers=merged)
        resp = conn.getresponse()
        raw = resp.read()
        response_headers = {}
        for name, value in resp.getheaders():
            response_headers[name] = value
        conn.close()
        return resp.status, response_headers, json.loads(raw.decode())

    def raw_request(self, method, path, body=None, headers=None):
        status, _, body = self.raw_request_full(method, path, body=body, headers=headers)
        return status, body

    def raw_get(self, path, headers=None):
        return self.raw_request("GET", path, headers=headers)

    def raw_post(self, path, body=None, headers=None):
        return self.raw_request("POST", path, body=body, headers=headers)

    def raw_post_full(self, path, body=None, headers=None):
        return self.raw_request_full("POST", path, body=body, headers=headers)

    def raw_patch(self, path, body=None, headers=None):
        return self.raw_request("PATCH", path, body=body, headers=headers)

    def raw_delete(self, path, headers=None):
        return self.raw_request("DELETE", path, headers=headers)

    def auth(self, token):
        return {"Authorization": "Bearer " + token}

    def login_device(self, name, platform):
        status, body = self.raw_post(
            "/api/v1/auth/login", {"password": PW, "device_name": name, "platform": platform}
        )
        self.assertEqual(status, 200)
        return body["token"], body["device"]

    def test_v1_login_issues_per_device_token(self):
        s1, b1 = self.raw_post("/api/v1/auth/login", {"password": PW, "device_name": "Task8Mac", "platform": "mac"})
        s2, b2 = self.raw_post("/api/v1/auth/login", {"password": PW, "device_name": "Task8Mac", "platform": "mac"})
        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)
        self.assertNotEqual(b1["token"], b2["token"])  # 每次登录独立 token
        self.assertEqual(b1["device"]["id"], b2["device"]["id"])  # 同名同平台复用设备
        self.assertEqual(b1["device"]["name"], "Task8Mac")
        self.assertTrue(b1["token"].startswith("cps_"))
        with app.db() as conn:
            hashes = [row[0] for row in conn.execute("select token_hash from device_tokens")]
        self.assertNotIn(b1["token"], hashes)  # 只存哈希
        self.assertIn(hashlib.sha256(b1["token"].encode()).hexdigest(), hashes)

    def test_v1_login_wrong_password_401(self):
        with app.db() as conn:
            conn.execute("delete from login_failures")
        s, b = self.raw_post("/api/v1/auth/login", {"password": "wrong-password", "device_name": "x", "platform": "mac"})
        self.assertEqual(s, 401)
        self.assertEqual(b["error"]["code"], "invalid_credentials")

    def test_v1_login_rate_limited(self):
        with app.db() as conn:
            conn.execute("delete from login_failures")
        for _ in range(8):
            s, b = self.raw_post("/api/v1/auth/login", {"password": "wrong-password", "device_name": "x", "platform": "mac"})
            self.assertEqual(s, 401)
        s, b = self.raw_post("/api/v1/auth/login", {"password": PW, "device_name": "x", "platform": "mac"})
        self.assertEqual(s, 429)
        self.assertEqual(b["error"]["code"], "login_locked")
        with app.db() as conn:
            conn.execute("delete from login_failures")

    def test_v1_devices_requires_auth_and_lists(self):
        token, device = self.login_device("ListMac", "mac")
        s, b = self.raw_get("/api/v1/devices", headers=self.auth(token))
        self.assertEqual(s, 200)
        entry = next((d for d in b["devices"] if d["id"] == device["id"]), None)
        self.assertIsNotNone(entry)
        self.assertEqual(entry["name"], "ListMac")
        self.assertEqual(entry["platform"], "mac")
        for key in ("id", "name", "platform", "online", "last_seen_at"):
            self.assertIn(key, entry)
        self.assertTrue(entry["online"])  # 刚登录，last_seen_at 新鲜
        s, b = self.raw_get("/api/v1/devices")
        self.assertEqual(s, 401)
        self.assertEqual(b["error"]["code"], "unauthorized")

    def test_v1_logout_revokes_token(self):
        token, device = self.login_device("LogoutMac", "mac")
        s, b = self.raw_post("/api/v1/auth/logout", headers=self.auth(token))
        self.assertEqual(s, 200)
        s, b = self.raw_get("/api/v1/devices", headers=self.auth(token))
        self.assertEqual(s, 401)
        self.assertEqual(b["error"]["code"], "token_revoked")

    def test_v1_web_login_sets_secure_httponly_cookie(self):
        status, headers, body = self.raw_post_full(
            "/api/v1/auth/login",
            {"password": PW, "device_name": "CookieAttr", "platform": "web", "client": "web"},
        )
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"]
        for attr in ("webclip_v1=", "Secure", "HttpOnly", "SameSite=Lax", "Path=/", "Max-Age=2592000"):
            self.assertIn(attr, cookie)

    def test_v1_cookie_auth_works_without_bearer(self):
        status, headers, body = self.raw_post_full(
            "/api/v1/auth/login",
            {"password": PW, "device_name": "CookieWeb", "platform": "web", "client": "web"},
        )
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        s, b = self.raw_get("/api/v1/devices", headers={"Cookie": cookie})
        self.assertEqual(s, 200)
        entry = next((d for d in b["devices"] if d["name"] == "CookieWeb"), None)
        self.assertIsNotNone(entry)

    def test_v1_logout_clears_cookie(self):
        status, headers, body = self.raw_post_full(
            "/api/v1/auth/login",
            {"password": PW, "device_name": "LogoutWeb", "platform": "web"},
            headers={"X-Client": "web"},
        )
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        s, h, b = self.raw_request_full("POST", "/api/v1/auth/logout", headers={"Cookie": cookie})
        self.assertEqual(s, 200)
        self.assertIn("Max-Age=0", h["Set-Cookie"])
        s, b = self.raw_get("/api/v1/devices", headers={"Cookie": cookie})
        self.assertEqual(s, 401)

    def test_v1_heartbeat_path_must_match_token(self):
        token_a, dev_a = self.login_device("HeartA", "mac")
        token_b, dev_b = self.login_device("HeartB", "android")
        s, b = self.raw_post(f"/api/v1/devices/{dev_b['id']}/heartbeat", headers=self.auth(token_a))
        self.assertEqual(s, 403)
        self.assertEqual(b["error"]["code"], "device_mismatch")
        with app.db() as conn:
            conn.execute("update devices set last_seen_at=0 where id=?", (dev_b["id"],))
        s, b = self.raw_post(f"/api/v1/devices/{dev_b['id']}/heartbeat", headers=self.auth(token_b))
        self.assertEqual(s, 200)
        with app.db() as conn:
            seen = conn.execute("select last_seen_at from devices where id=?", (dev_b["id"],)).fetchone()[0]
            changes = conn.execute(
                "select * from sync_changes where entity='device' and entity_id=?", (dev_b["id"],)
            ).fetchall()
        self.assertGreater(seen, 0)
        self.assertTrue(changes)

    def test_v1_delete_device_revokes_all_tokens(self):
        token_v1, dev_v = self.login_device("Victim", "android")
        token_v2, _ = self.login_device("Victim", "android")
        token_admin, dev_admin = self.login_device("Admin", "mac")
        s, b = self.raw_delete(f"/api/v1/devices/{dev_v['id']}", headers=self.auth(token_admin))
        self.assertEqual(s, 200)
        self.assertEqual(b["revoked_tokens"], 2)
        for token in (token_v1, token_v2):
            s, b = self.raw_get("/api/v1/devices", headers=self.auth(token))
            self.assertEqual(s, 401)
        s, b = self.raw_delete(f"/api/v1/devices/{dev_v['id']}", headers=self.auth(token_admin))
        self.assertEqual(s, 409)
        s, b = self.raw_delete("/api/v1/devices/no-such-device", headers=self.auth(token_admin))
        self.assertEqual(s, 404)
        s, b = self.raw_delete(f"/api/v1/devices/{dev_admin['id']}", headers=self.auth(token_admin))
        self.assertEqual(s, 200)  # 允许撤销自己
        s, b = self.raw_get("/api/v1/devices", headers=self.auth(token_admin))
        self.assertEqual(s, 401)

    def test_v1_rename_device(self):
        token, dev = self.login_device("OldName", "mac")
        s, b = self.raw_patch(f"/api/v1/devices/{dev['id']}", {"name": "NewName"}, headers=self.auth(token))
        self.assertEqual(s, 200)
        self.assertEqual(b["device"]["name"], "NewName")
        with app.db() as conn:
            name = conn.execute("select name from devices where id=?", (dev["id"],)).fetchone()[0]
        self.assertEqual(name, "NewName")
        s, b = self.raw_patch("/api/v1/devices/no-such-device", {"name": "X"}, headers=self.auth(token))
        self.assertEqual(s, 404)
        s, b = self.raw_patch(f"/api/v1/devices/{dev['id']}", {"name": "  "}, headers=self.auth(token))
        self.assertEqual(s, 400)

    def test_sync_full_from_zero_and_incremental(self):
        token, dev = self.login_device("SyncMac", "mac")
        s, b = self.raw_get("/api/v1/sync?cursor=0", headers=self.auth(token))
        self.assertEqual(s, 200)
        self.assertTrue(any(c["entity"] == "device" and c["entity_id"] == dev["id"] for c in b["changes"]))
        cursor = b["next_cursor"]
        self.raw_patch(f"/api/v1/devices/{dev['id']}", {"name": "SyncMac2"}, headers=self.auth(token))
        s, b = self.raw_get(f"/api/v1/sync?cursor={cursor}", headers=self.auth(token))
        self.assertEqual(s, 200)
        self.assertEqual(len(b["changes"]), 1)  # 只增量
        self.assertEqual(b["changes"][0]["op"], "upsert")
        self.assertEqual(b["changes"][0]["entity"], "device")
        self.assertGreater(b["next_cursor"], cursor)

    def test_sync_bad_cursor_requires_full(self):
        token, _ = self.login_device("SyncBad", "mac")
        for bad in ("abc", "-1"):
            s, b = self.raw_get(f"/api/v1/sync?cursor={bad}", headers=self.auth(token))
            self.assertEqual(s, 409)
            self.assertEqual(b["error"]["code"], "full_sync_required")
        s, b = self.raw_get("/api/v1/sync", headers=self.auth(token))
        self.assertEqual(s, 409)
        self.assertEqual(b["error"]["code"], "full_sync_required")

    def test_sync_tombstone_on_delete(self):
        token_v, dev_v = self.login_device("SyncVictim", "android")
        token_a, _ = self.login_device("SyncAdmin", "mac")
        s, b = self.raw_get("/api/v1/sync?cursor=0", headers=self.auth(token_a))
        cursor = b["next_cursor"]
        self.raw_delete(f"/api/v1/devices/{dev_v['id']}", headers=self.auth(token_a))
        s, b = self.raw_get(f"/api/v1/sync?cursor={cursor}", headers=self.auth(token_a))
        self.assertEqual(s, 200)
        self.assertTrue(any(c["op"] == "delete" and c["entity_id"] == dev_v["id"] for c in b["changes"]))
        self.assertIn({"entity": "device", "entity_id": dev_v["id"]}, b["tombstones"])

    def test_sync_requires_auth(self):
        s, b = self.raw_get("/api/v1/sync?cursor=0")
        self.assertEqual(s, 401)
        self.assertEqual(b["error"]["code"], "unauthorized")

    def test_sync_prunes_window_and_stale_cursor_requires_full(self):
        token, dev = self.login_device("SyncPrune", "mac")
        old_keep = app.SYNC_KEEP
        app.SYNC_KEEP = 5
        try:
            with app.db() as conn:
                for i in range(10):
                    app.record_change(conn, "item", f"prune-{i}", "upsert")
                count = conn.execute("select count(*) from sync_changes").fetchone()[0]
                min_seq = conn.execute("select min(seq) from sync_changes").fetchone()[0]
        finally:
            app.SYNC_KEEP = old_keep
        self.assertLessEqual(count, 6)  # 窗口 5 + 登录产生的 1 条之外被裁剪
        s, b = self.raw_get("/api/v1/sync?cursor=1", headers=self.auth(token))
        if min_seq > 1:
            self.assertEqual(s, 409)
            self.assertEqual(b["error"]["code"], "full_sync_required")

    def test_v1_events_streams_version_notification(self):
        token, _ = self.login_device("EventsMac", "mac")
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        try:
            conn.request("GET", "/api/v1/events", headers=self.auth(token))
            resp = conn.getresponse()
            self.assertEqual(resp.status, 200)
            self.assertIn("text/event-stream", resp.getheader("Content-Type"))
            chunk = resp.read1(256).decode()
            self.assertIn("data:", chunk)  # 首包即含版本号
            self.assertNotIn("<html", chunk)  # 不带旧 HTML
        finally:
            conn.close()

    def test_v1_events_requires_auth(self):
        s, b = self.raw_get("/api/v1/events")
        self.assertEqual(s, 401)
        self.assertEqual(b["error"]["code"], "unauthorized")

    def test_idempotent_rename_returns_first_result(self):
        token, dev = self.login_device("IdemDev", "mac")
        headers = {**self.auth(token), "Idempotency-Key": "k-rename-1"}
        s1, b1 = self.raw_patch(f"/api/v1/devices/{dev['id']}", {"name": "NameA"}, headers=headers)
        s2, b2 = self.raw_patch(f"/api/v1/devices/{dev['id']}", {"name": "NameB"}, headers=headers)
        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)
        self.assertEqual(b1, b2)
        with app.db() as conn:
            name = conn.execute("select name from devices where id=?", (dev["id"],)).fetchone()[0]
        self.assertEqual(name, "NameA")  # 第二次未真正执行

    def test_idempotent_replay_sets_header(self):
        token, dev = self.login_device("IdemHeader", "mac")
        headers = {**self.auth(token), "Idempotency-Key": "k-header-1"}
        self.raw_patch(f"/api/v1/devices/{dev['id']}", {"name": "H1"}, headers=headers)
        s, h, b = self.raw_request_full("PATCH", f"/api/v1/devices/{dev['id']}", body={"name": "H2"}, headers=headers)
        self.assertEqual(s, 200)
        self.assertEqual(h.get("X-Idempotent-Replay"), "1")
        self.assertEqual(b["device"]["name"], "H1")

    def test_idempotent_delete_replays_result(self):
        token_a, _ = self.login_device("IdemAdmin", "mac")
        token_v, dev_v = self.login_device("IdemVictim", "android")
        headers = {**self.auth(token_a), "Idempotency-Key": "k-delete-1"}
        s1, b1 = self.raw_delete(f"/api/v1/devices/{dev_v['id']}", headers=headers)
        s2, b2 = self.raw_delete(f"/api/v1/devices/{dev_v['id']}", headers=headers)
        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)  # 重放首个结果而不是 409
        self.assertEqual(b1, b2)

    def test_idempotency_scoped_per_device(self):
        token_a, dev_a = self.login_device("IdemA", "mac")
        token_b, dev_b = self.login_device("IdemB", "mac")
        key = {"Idempotency-Key": "k-shared"}
        s1, b1 = self.raw_patch(f"/api/v1/devices/{dev_a['id']}", {"name": "NameA"}, headers={**self.auth(token_a), **key})
        s2, b2 = self.raw_patch(f"/api/v1/devices/{dev_b['id']}", {"name": "NameB"}, headers={**self.auth(token_b), **key})
        self.assertEqual(b1["device"]["name"], "NameA")
        self.assertEqual(b2["device"]["name"], "NameB")  # 另一设备同 key 不复用

    def test_idempotency_expired_key_executes_again(self):
        token, dev = self.login_device("IdemExpired", "mac")
        with app.db() as conn:
            conn.execute(
                "insert into idempotency_keys(device_id, idem_key, result_json, created_at, expires_at) values(?,?,?,?,?)",
                (dev["id"], "k-expired", json.dumps({"device": {"name": "Stale"}}), "2000-01-01T00:00:00Z", "2000-01-02T00:00:00Z"),
            )
        s, b = self.raw_patch(
            f"/api/v1/devices/{dev['id']}", {"name": "Fresh"},
            headers={**self.auth(token), "Idempotency-Key": "k-expired"},
        )
        self.assertEqual(s, 200)
        self.assertEqual(b["device"]["name"], "Fresh")

    def test_v1_post_text_item(self):
        token, dev = self.login_device("TextMac", "mac")
        s, b = self.raw_post(
            "/api/v1/items",
            {"kind": "text", "text": "hello v1", "note": "备注", "source_device": "web"},
            headers=self.auth(token),
        )
        self.assertEqual(s, 200)
        item = b["item"]
        self.assertEqual(item["kind"], "text")
        self.assertEqual(item["text"], "hello v1")
        self.assertEqual(item["note"], "备注")
        self.assertEqual(item["source_device"], dev["id"])  # body 里的 source_device 被忽略
        with app.db() as conn:
            row = conn.execute("select id from items where id=?", (item["id"],)).fetchone()
            changes = conn.execute(
                "select * from sync_changes where entity='item' and entity_id=?", (item["id"],)
            ).fetchall()
        self.assertIsNotNone(row)
        self.assertTrue(changes)

    def test_v1_items_requires_auth(self):
        s, b = self.raw_post("/api/v1/items", {"kind": "text", "text": "x"})
        self.assertEqual(s, 401)
        self.assertEqual(b["error"]["code"], "unauthorized")

    def test_v1_source_device_cannot_be_forged(self):
        token, dev = self.login_device("ForgeMac", "mac")
        s, b = self.raw_post(
            "/api/v1/items", {"kind": "text", "text": "forge", "source_device": "web"}, headers=self.auth(token)
        )
        self.assertEqual(s, 200)
        self.assertEqual(b["item"]["source_device"], dev["id"])
        with app.db() as conn:
            stored = conn.execute("select source_device from items where id=?", (b["item"]["id"],)).fetchone()[0]
        self.assertEqual(stored, dev["id"])

    def test_v1_upload_file_records_original_blob(self):
        token, dev = self.login_device("UploadMac", "mac")
        data = b"\x89PNG\r\n\x1a\n" + b"fakepng" * 10
        body = self.multipart_body("----t14", [("file", "pic.png", "image/png", data)])
        s, b = self.raw_request(
            "POST", "/api/v1/items", body=body,
            headers={**self.auth(token), "Content-Type": "multipart/form-data; boundary=----t14"},
        )
        self.assertEqual(s, 200)
        item = b["item"]
        self.assertEqual(item["kind"], "image")
        self.assertEqual(item["mime"], "image/png")
        self.assertEqual(item["size"], len(data))
        with app.db() as conn:
            blob = conn.execute(
                "select * from item_blobs where item_id=? and variant='original'", (item["id"],)
            ).fetchone()
        self.assertIsNotNone(blob)
        self.assertEqual(blob["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(blob["size"], len(data))
        stored = blob["stored_name"]
        self.assertEqual((app.FILES_DIR / stored).read_bytes(), data)
        self.assertFalse((app.FILES_DIR / (stored + ".part")).exists())  # 无 .part 残留

    def test_v1_upload_respects_capacity(self):
        token, dev = self.login_device("CapMac", "mac")
        old_limit = app.MAX_FILE_BYTES
        app.MAX_FILE_BYTES = 10
        try:
            body = self.multipart_body("----t14cap", [("file", "big.bin", "application/octet-stream", b"x" * 20)])
            s, b = self.raw_request(
                "POST", "/api/v1/items", body=body,
                headers={**self.auth(token), "Content-Type": "multipart/form-data; boundary=----t14cap"},
            )
            self.assertEqual(s, 413)
            self.assertEqual(b["error"]["code"], "file_too_large")
        finally:
            app.MAX_FILE_BYTES = old_limit

    def test_idempotent_create_returns_first_result(self):
        token, dev = self.login_device("IdemItem", "mac")
        headers = {**self.auth(token), "Idempotency-Key": "k-item-1"}
        s1, b1 = self.raw_post("/api/v1/items", {"kind": "text", "text": "hi"}, headers=headers)
        s2, b2 = self.raw_post("/api/v1/items", {"kind": "text", "text": "hi"}, headers=headers)
        self.assertEqual(s1, 200)
        self.assertEqual(b1["item"]["id"], b2["item"]["id"])
        with app.db() as conn:
            count = conn.execute("select count(*) from items where text='hi'").fetchone()[0]
        self.assertEqual(count, 1)

    def test_v1_write_bumps_sse_version(self):
        token, dev = self.login_device("SseMac", "mac")
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        try:
            conn.request("GET", "/api/v1/events", headers=self.auth(token))
            resp = conn.getresponse()
            self.assertIn(b"data:", resp.read1(256))
            s, b = self.raw_post("/api/v1/items", {"kind": "text", "text": "sse bump"}, headers=self.auth(token))
            self.assertEqual(s, 200)
            buf = b""
            while b"event: sync" not in buf:
                buf += resp.read1(256)
            self.assertIn(b"data:", buf)
        finally:
            conn.close()

    def test_v1_error_shape(self):
        status, body = self.raw_get("/api/v1/devices")
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")
        self.assertIn("message", body["error"])

    def test_v1_unknown_route_404_not_found(self):
        status, body = self.raw_get("/api/v1/nope")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "not_found")

    def test_migrate_v1_creates_tables_and_is_repeatable(self):
        with app.db() as conn:
            app.migrate_v1(conn)
            app.migrate_v1(conn)
            tables = {row[0] for row in conn.execute("select name from sqlite_master where type='table'")}
        for table in ("device_tokens", "item_blobs", "sync_changes", "idempotency_keys"):
            self.assertIn(table, tables)

    def test_migrate_v1_backfills_item_blobs_original(self):
        data = b"copy sync blob backfill" * 100
        stored = "migrate-backfill.bin"
        (app.FILES_DIR / stored).write_bytes(data)
        now = int(time.time())
        try:
            with app.db() as conn:
                conn.execute(
                    "insert into items(id,kind,name,stored_name,mime,size,created_at,expires_at) values(?,?,?,?,?,?,?,?)",
                    ("migrate-backfill", "file", "backfill.bin", stored, "application/octet-stream", len(data), now, now + 86400),
                )
                app.migrate_v1(conn)
                row = conn.execute(
                    "select variant, stored_name, size, sha256 from item_blobs where item_id='migrate-backfill'"
                ).fetchone()
                self.assertIsNotNone(row)
                self.assertEqual(row["variant"], "original")
                self.assertEqual(row["stored_name"], stored)
                self.assertEqual(row["size"], len(data))
                self.assertEqual(row["sha256"], hashlib.sha256(data).hexdigest())
                app.migrate_v1(conn)  # 二次执行不重复回填
                count = conn.execute(
                    "select count(*) from item_blobs where item_id='migrate-backfill'"
                ).fetchone()[0]
                self.assertEqual(count, 1)
        finally:
            with app.db() as conn:
                conn.execute("delete from item_blobs where item_id='migrate-backfill'")
                conn.execute("delete from items where id='migrate-backfill'")
            (app.FILES_DIR / stored).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
