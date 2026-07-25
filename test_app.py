import os
import tempfile
import time
import unittest


tmp = tempfile.TemporaryDirectory()
os.environ.update(
    WEBCLIP_DATA_DIR=tmp.name,
    WEBCLIP_PASSWORD="review-password-123",
    WEBCLIP_SESSION_SECRET="review-session-secret-123",
    WEBCLIP_COOKIE_SECURE="0",
)

import app


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
        self.assertIn("对方已接收", page)
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


if __name__ == "__main__":
    unittest.main()
