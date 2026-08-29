package xyz.copysync.copysync

import android.app.Activity
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/// CopySync Android 原生桥（MethodChannel xyz.copysync/bridge）。
/// 逐能力迁移自旧工程 MainActivity/SyncService（AnyCopy），
/// 错误码与 Dart 侧 BridgeErrorCodes 一致：
/// permission_denied / cancelled / not_found / not_ready /
/// checksum_mismatch / invalid_args / system_error。
class CopySyncBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "xyz.copysync/bridge"
        private const val TAG = "CopySyncBridge"
        private const val DELIVERY_CHANNEL = "copysync_delivery"
        private const val PREFS = "copysync"
        private const val RECEIVE_DIRECTORY = "CopySync"
        private const val RECEIVED_FILE_PREFIX = "received_file_"
        private const val PENDING_DOWNLOAD_PREFIX = "pending_download_"
        private const val UPDATE_APK_NAME = "copysync-update.apk"
        private const val PICKER_REQUEST_CODE = 24027
        private const val PICKER_TOO_LARGE_MESSAGE = "文件超过 100MB 上限，无法上传"
        internal const val MAX_PICKER_BYTES = 100L * 1024L * 1024L
        internal fun pickerSizeAllowed(size: Long): Boolean =
            size < 0L || size <= MAX_PICKER_BYTES
        private val FILE_MANAGER_PACKAGES = arrayOf(
            "com.sec.android.app.myfiles",
            "com.google.android.apps.nbu.files",
            "com.google.android.documentsui"
        )
    }

    private val context: Context get() = activity.applicationContext
    private var channel: MethodChannel? = null
    private var pickerResult: MethodChannel.Result? = null
    private val io = Executors.newCachedThreadPool()

    /// 待确认分享（内存态；进程被杀时分享 intent 会随启动重新投递）。
    private data class SharedFile(val name: String, val mime: String, val path: String, val size: Long)
    private data class PendingShare(val id: String, val text: String?, val files: List<SharedFile>)
    private val pendingShares = LinkedHashMap<String, PendingShare>()

    private data class DownloadRecord(val deliveryId: String, val name: String, val mime: String)
    private val regularDownloads = ConcurrentHashMap<Long, DownloadRecord>()

    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
            if (id < 0) return
            io.execute { finishDownload(id) }
        }
    }

    fun attach(channel: MethodChannel) {
        this.channel = channel
        createDeliveryChannel()
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(downloadReceiver, filter)
        }
        Log.i(TAG, "native bridge attached on $CHANNEL_NAME")
    }

    fun detach() {
        try {
            context.unregisterReceiver(downloadReceiver)
        } catch (error: RuntimeException) {
            Log.w(TAG, "download receiver not registered", error)
        }
        channel = null
    }

    // ------------------------------------------------------------ intent 分享

    /// 捕获 ACTION_SEND / SEND_MULTIPLE：文本直接存，文件复制到缓存目录
    ///（授权 uri 在 confirm 前可能失效，必须立即落缓存，语义同旧工程
    /// pendingShare + uploadShare 的即时读取）。
    fun handleShareIntent(intent: Intent?): Boolean {
        if (intent == null) return false
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return false
        return try {
            val id = "share-" + UUID.randomUUID().toString()
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            val files = ArrayList<SharedFile>()
            for (uri in sharedUris(intent)) {
                files.add(copyToShareCache(id, uri))
            }
            if (text.isNullOrBlank() && files.isEmpty()) return false
            pendingShares[id] = PendingShare(id, text, files)
            channel?.invokeMethod("share.pending", mapOf("id" to id))
            true
        } catch (error: RuntimeException) {
            Log.e(TAG, "share capture failed", error)
            false
        }
    }

    private fun sharedUris(intent: Intent): List<Uri> {
        val result = ArrayList<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { result.addAll(it) }
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { result.add(it) }
        }
        intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                val uri = clip.getItemAt(i).uri
                if (uri != null && !result.contains(uri)) result.add(uri)
            }
        }
        return result
    }

    private fun copyToShareCache(shareId: String, uri: Uri): SharedFile {
        val name = displayName(uri)
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        val dir = File(context.cacheDir, "share_inbox/$shareId")
        dir.mkdirs()
        val target = File(dir, name)
        context.contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        } ?: throw IllegalStateException("无法读取 $name")
        return SharedFile(name, mime, target.absolutePath, target.length())
    }

    private fun displayName(uri: Uri): String {
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val name = cursor.getString(0)
                        if (!name.isNullOrBlank()) return name
                    }
                }
        } catch (error: Exception) {
            Log.w(TAG, "display name lookup failed for $uri", error)
        }
        return uri.lastPathSegment ?: "CopySync-file"
    }

    // ------------------------------------------------------------ MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "clipboard.readText" -> result.success(clipboardReadText())
                "clipboard.readImage" -> clipboardReadImage(result)
                "clipboard.write" -> clipboardWrite(call, result)
                "background.start" -> backgroundStart(call, result)
                "background.stop" -> backgroundStop(result)
                "notify.show" -> notifyShow(call, result)
                "share.pending" -> result.success(sharePending())
                "share.confirm" -> shareConfirm(call, result)
                "picker.openFile" -> openPicker(call, result)
                "download.enqueue" -> downloadEnqueue(call, result)
                "download.reconcile" -> io.execute { result.success(downloadReconcile()) }
                "files.saveSent" -> io.execute { saveSentFile(call, result) }
                "files.saveReceived" -> io.execute { saveFile(call, result) }
                "files.revealReceived" -> revealReceived(call, result)
                "files.openReceived" -> openReceived(call, result)
                "update.check" -> io.execute { updateCheck(call, result) }
                "update.download" -> io.execute { updateDownload(call, result) }
                "update.install" -> updateInstall(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e(TAG, "${call.method} failed", error)
            result.error("system_error", error.message ?: "系统错误", null)
        }
    }

    // ------------------------------------------------------------- clipboard

    private fun clipboardReadText(): String? {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val text = clip.getItemAt(0).coerceToText(context) ?: return null
        return text.toString().ifEmpty { null }
    }

    private fun clipboardReadImage(result: MethodChannel.Result) {
        io.execute {
            try {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = clipboard.primaryClip
                var base64: String? = null
                if (clip != null) {
                    for (i in 0 until clip.itemCount) {
                        val uri = clip.getItemAt(i).uri ?: continue
                        val type = context.contentResolver.getType(uri)
                        if (type == null || !type.startsWith("image/")) continue
                        val bitmap = context.contentResolver.openInputStream(uri)?.use {
                            BitmapFactory.decodeStream(it)
                        } ?: continue
                        val output = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                        base64 = android.util.Base64.encodeToString(
                            output.toByteArray(), android.util.Base64.NO_WRAP)
                        break
                    }
                }
                result.success(base64)
            } catch (error: Exception) {
                Log.e(TAG, "clipboard.readImage failed", error)
                result.error("system_error", error.message, null)
            }
        }
    }

    private fun clipboardWrite(call: MethodCall, result: MethodChannel.Result) {
        // ignoreNext：Android 无原生剪贴板 watcher，去重由 Dart 同步循环负责，仅接受参数。
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        when (call.argument<String>("kind")) {
            "text" -> {
                val text = call.argument<String>("text")
                if (text == null) {
                    result.error("invalid_args", "clipboard.write 缺少 text", null)
                    return
                }
                clipboard.setPrimaryClip(ClipData.newPlainText("CopySync", text))
                result.success(null)
            }
            "image" -> {
                val data = call.argument<String>("dataBase64")
                if (data == null) {
                    result.error("invalid_args", "clipboard.write 缺少 dataBase64", null)
                    return
                }
                try {
                    val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
                    val dir = File(context.cacheDir, "clipboard")
                    dir.mkdirs()
                    val file = File(dir, "copysync-clip.png")
                    file.writeBytes(bytes)
                    val uri = FileProvider.getUriForFile(
                        context, "${context.packageName}.fileprovider", file)
                    clipboard.setPrimaryClip(
                        ClipData.newUri(context.contentResolver, "CopySync 图片", uri))
                    result.success(null)
                } catch (error: Exception) {
                    Log.e(TAG, "clipboard.write image failed", error)
                    result.error("system_error", error.message ?: "图片写入剪贴板失败", null)
                }
            }
            else -> result.error("invalid_args", "clipboard.write 需要 kind=text|image", null)
        }
    }

    // ------------------------------------------------------------- background

    private fun backgroundStart(call: MethodCall, result: MethodChannel.Result) {
        val mode = call.argument<String>("mode") ?: "realtime"
        if (Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission_denied", "通知权限未授予", null)
            return
        }
        try {
            val intent = Intent(context, SyncService::class.java).putExtra("mode", mode)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
            result.success(null)
        } catch (error: Exception) {
            Log.e(TAG, "background.start failed", error)
            result.error("system_error", error.message ?: "前台服务启动失败", null)
        }
    }

    private fun backgroundStop(result: MethodChannel.Result) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(SyncService.SYNC_MODE, "off").apply()
        context.stopService(Intent(context, SyncService::class.java))
        context.getSystemService(NotificationManager::class.java).cancel(SyncService.NOTIFY_ID)
        result.success(null)
    }

    // ----------------------------------------------------------------- notify

    private fun notifyShow(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title") ?: "CopySync"
        val body = call.argument<String>("body") ?: ""
        val id = call.argument<String>("id")
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (id != null) open.putExtra("deliveryId", id)
        val action = PendingIntent.getActivity(
            context, id?.hashCode() ?: 0, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, DELIVERY_CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(action)
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java)
            .notify(id?.hashCode() ?: System.currentTimeMillis().toInt(), notification)
        result.success(null)
    }

    private fun createDeliveryChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(
            DELIVERY_CHANNEL, "CopySync 接收提醒", NotificationManager.IMPORTANCE_HIGH)
        channel.description = "其他设备发送内容到 Android 时提醒"
        context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    // ------------------------------------------------------------------ share

    private fun sharePending(): List<Map<String, Any?>> {
        return pendingShares.values.map { share ->
            mapOf(
                "id" to share.id,
                "text" to share.text,
                "files" to share.files.map { file ->
                    mapOf(
                        "name" to file.name,
                        "mime" to file.mime,
                        "path" to file.path,
                        "size" to file.size,
                    )
                },
            )
        }
    }

    private fun shareConfirm(call: MethodCall, result: MethodChannel.Result) {
        val ids = call.argument<List<String>>("ids") ?: emptyList()
        for (id in ids) {
            pendingShares.remove(id)
            File(context.cacheDir, "share_inbox/$id").deleteRecursively()
        }
        result.success(null)
    }

    // ------------------------------------------------------------------ picker

    /// 通过 Android SAF 选择文件；结果只包含应用缓存路径和元数据。
    private fun openPicker(call: MethodCall, result: MethodChannel.Result) {
        if (pickerResult != null) {
            result.error("not_ready", "文件选择器仍在工作", null)
            return
        }
        val imagesOnly = call.argument<Boolean>("imagesOnly") == true
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(if (imagesOnly) "image/*" else "*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        pickerResult = result
        try {
            activity.startActivityForResult(intent, PICKER_REQUEST_CODE)
        } catch (error: RuntimeException) {
            pickerResult = null
            result.error("system_error", error.message ?: "无法打开文件选择器", null)
        }
    }

    /// Activity 回调中只在原生侧流式复制文件，避免 FileResponse.bytes 的
    /// 全量 MethodChannel 解码。
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICKER_REQUEST_CODE) return false
        val callback = pickerResult ?: return true
        pickerResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            callback.success(null)
            return true
        }
        io.execute {
            try {
                val picked = copyPickedFile(uri)
                activity.runOnUiThread { callback.success(picked) }
            } catch (error: PickerTooLargeException) {
                activity.runOnUiThread {
                    callback.error("file_too_large", PICKER_TOO_LARGE_MESSAGE, null)
                }
            } catch (error: Exception) {
                Log.e(TAG, "picker.openFile failed", error)
                activity.runOnUiThread {
                    callback.error("system_error", error.message ?: "无法读取所选文件", null)
                }
            }
        }
        return true
    }

    private fun copyPickedFile(uri: Uri): Map<String, Any?> {
        val name = safeReceiveName(displayName(uri))
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        val dir = File(context.cacheDir, "picker/" + UUID.randomUUID().toString())
        dir.mkdirs()
        val target = File(dir, name)
        try {
            val knownSize = sourceSize(uri)
            if (knownSize != null && !pickerSizeAllowed(knownSize)) {
                throw PickerTooLargeException()
            }
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        if (count.toLong() > MAX_PICKER_BYTES - copied) {
                            throw PickerTooLargeException()
                        }
                        output.write(buffer, 0, count)
                        copied += count
                    }
                }
            } ?: throw IllegalStateException("无法读取 $name")
            return mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "mime" to mime,
                "size" to target.length(),
            )
        } catch (error: Exception) {
            target.delete()
            dir.deleteRecursively()
            throw error
        }
    }

    private fun sourceSize(uri: Uri): Long? {
        return try {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.SIZE), null, null, null,
            )?.use { cursor ->
                if (!cursor.moveToFirst() || cursor.isNull(0)) null
                else cursor.getLong(0).takeIf { it >= 0L }
            }
        } catch (error: Exception) {
            Log.w(TAG, "picker size lookup failed", error)
            null
        }
    }

    private class PickerTooLargeException : Exception()

    // --------------------------------------------------------------- download

    private fun downloadEnqueue(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")
        if (url.isNullOrBlank() || name.isNullOrBlank()) {
            result.error("invalid_args", "download.enqueue 需要 url/name", null)
            return
        }
        val deliveryId = call.argument<String>("deliveryId") ?: ""
        val mime = call.argument<String>("mime").let {
            if (it.isNullOrBlank()) "application/octet-stream" else it
        }
        try {
            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(name)
                .setMimeType(mime)
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS, "$RECEIVE_DIRECTORY/$name")
            call.argument<Map<String, String>>("headers")?.forEach { (key, value) ->
                request.addRequestHeader(key, value)
            }
            val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val id = manager.enqueue(request)
            val record = DownloadRecord(deliveryId, name, mime)
            regularDownloads[id] = record
            savePendingDownload(id, record)
            result.success(id)
        } catch (error: Exception) {
            Log.e(TAG, "download.enqueue failed", error)
            result.error("system_error", error.message ?: "下载入队失败", null)
        }
    }

    /// 下载完成回调（广播或 reconcile 驱动）：成功落盘则记录 received_file_，
    /// 并推送 download.completed 事件给 Dart；失败同样推送。
    private fun finishDownload(id: Long) {
        val record = regularDownloads.remove(id) ?: loadPendingDownload(id) ?: return
        val state = when {
            receivedFileExists(record.name) -> "ready"
            else -> downloadStatus(id)
        }
        when (state) {
            "ready" -> {
                clearPendingDownload(id)
                if (record.deliveryId.isNotEmpty()) {
                    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                        .putString(RECEIVED_FILE_PREFIX + record.deliveryId, record.name).apply()
                }
            }
            "pending" -> return
            else -> clearPendingDownload(id)
        }
        channel?.invokeMethod(
            "download.completed",
            mapOf("id" to id, "deliveryId" to record.deliveryId,
                "name" to record.name, "state" to state),
        )
    }

    private fun downloadStatus(id: Long): String {
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return try {
            manager.query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
                if (!cursor.moveToFirst()) return "missing"
                when (cursor.getInt(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                    DownloadManager.STATUS_SUCCESSFUL -> "ready"
                    DownloadManager.STATUS_FAILED -> "failed"
                    else -> "pending"
                }
            } ?: "missing"
        } catch (error: Exception) {
            Log.w(TAG, "download status query failed for $id", error)
            "missing"
        }
    }

    /// 重启恢复语义（旧工程 reconcilePendingDownloads）：遍历持久化的
    /// 未完成下载，返回每条 delivery 的 ready/pending/failed/missing。
    private fun downloadReconcile(): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val states = ArrayList<Map<String, Any?>>()
        val ids = prefs.all.keys
            .filter { it.startsWith(PENDING_DOWNLOAD_PREFIX) }
            .mapNotNull { it.removePrefix(PENDING_DOWNLOAD_PREFIX).toLongOrNull() }
        for (id in ids) {
            val record = regularDownloads[id] ?: loadPendingDownload(id)
            if (record == null) {
                clearPendingDownload(id)
                continue
            }
            var state = if (receivedFileExists(record.name)) "ready" else downloadStatus(id)
            if (state == "ready" && !receivedFileExists(record.name)) state = "missing"
            when (state) {
                "ready" -> {
                    clearPendingDownload(id)
                    if (record.deliveryId.isNotEmpty()) {
                        prefs.edit().putString(
                            RECEIVED_FILE_PREFIX + record.deliveryId, record.name).apply()
                    }
                }
                "failed", "missing" -> {
                    clearPendingDownload(id)
                    regularDownloads.remove(id)
                }
            }
            if (record.deliveryId.isNotEmpty()) {
                states.add(mapOf(
                    "deliveryId" to record.deliveryId,
                    "name" to record.name,
                    "state" to state,
                ))
            }
        }
        return states
    }

    private fun savePendingDownload(id: Long, record: DownloadRecord) {
        try {
            val json = JSONObject()
                .put("deliveryId", record.deliveryId)
                .put("name", record.name)
                .put("mime", record.mime)
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(PENDING_DOWNLOAD_PREFIX + id, json.toString()).apply()
        } catch (error: Exception) {
            Log.w(TAG, "persist pending download failed", error)
        }
    }

    private fun loadPendingDownload(id: Long): DownloadRecord? {
        return try {
            val value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(PENDING_DOWNLOAD_PREFIX + id, "") ?: ""
            if (value.isEmpty()) return null
            val json = JSONObject(value)
            DownloadRecord(
                json.optString("deliveryId"),
                json.optString("name", "CopySync-file"),
                json.optString("mime"),
            )
        } catch (error: Exception) {
            null
        }
    }

    private fun clearPendingDownload(id: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(PENDING_DOWNLOAD_PREFIX + id).apply()
    }

    // ------------------------------------------------------------------ files

    /// 已发送文件从应用缓存路径流式落盘 Download/CopySync，重名自动追加时间戳。
    private fun saveSentFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val itemId = call.argument<String>("itemId")
            val name = call.argument<String>("name")
            val path = call.argument<String>("path")
            if (itemId.isNullOrBlank() || name.isNullOrBlank() || path.isNullOrBlank()) {
                result.error("invalid_args", "saveSent 需要 itemId/name/path", null)
                return
            }
            val source = File(path).canonicalFile
            val cacheRoot = context.cacheDir.canonicalFile
            if (!source.isFile ||
                !source.path.startsWith(cacheRoot.path + File.separator)
            ) {
                result.error("not_found", "待保存文件不存在", null)
                return
            }
            val finalName = uniqueReceiveName(name)
            if (!copyToReceiveDir(finalName, source)) {
                result.error("system_error", "文件写入 Download/$RECEIVE_DIRECTORY 失败", null)
                return
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(RECEIVED_FILE_PREFIX + "sent:" + itemId, finalName).apply()
            result.success(finalName)
        } catch (error: Exception) {
            Log.e(TAG, "save sent file failed", error)
            result.error("system_error", error.message ?: "文件写入失败", null)
        }
    }

    /// 接收文件的旧 bytes 接口保留；已发送文件不再经过 Base64。
    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val recordId = call.argument<String>("deliveryId") ?: ""
            val name = call.argument<String>("name")
            val data = call.argument<String>("dataBase64")
            if (name.isNullOrBlank() || data == null) {
                result.error("invalid_args", "save 需要 name/dataBase64", null)
                return
            }
            val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
            val finalName = uniqueReceiveName(name)
            if (!writeToReceiveDir(finalName, bytes)) {
                result.error("system_error", "文件写入 Download/$RECEIVE_DIRECTORY 失败", null)
                return
            }
            if (recordId.isNotEmpty()) {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putString(RECEIVED_FILE_PREFIX + recordId, finalName).apply()
            }
            result.success(finalName)
        } catch (error: Exception) {
            Log.e(TAG, "save file failed", error)
            result.error("system_error", error.message ?: "文件写入失败", null)
        }
    }

    private fun writeToReceiveDir(name: String, bytes: ByteArray): Boolean {
        return if (Build.VERSION.SDK_INT >= 29) {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, guessMime(name))
                    put(MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/" + RECEIVE_DIRECTORY)
                }
                val uri = context.contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
                context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: return false
                true
            } catch (error: Exception) {
                Log.e(TAG, "mediastore write failed", error)
                false
            }
        } else {
            try {
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS), RECEIVE_DIRECTORY)
                dir.mkdirs()
                File(dir, name).writeBytes(bytes)
                true
            } catch (error: Exception) {
                Log.e(TAG, "legacy write failed", error)
                false
            }
        }
    }

    private fun copyToReceiveDir(name: String, source: File): Boolean {
        return try {
            source.inputStream().use { input ->
                if (Build.VERSION.SDK_INT >= 29) {
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                        put(MediaStore.MediaColumns.MIME_TYPE, guessMime(name))
                        put(MediaStore.MediaColumns.RELATIVE_PATH,
                            Environment.DIRECTORY_DOWNLOADS + "/" + RECEIVE_DIRECTORY)
                    }
                    val uri = context.contentResolver.insert(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
                    try {
                        val output = context.contentResolver.openOutputStream(uri)
                            ?: throw IllegalStateException("无法打开目标文件")
                        output.use { input.copyTo(it, 64 * 1024) }
                        true
                    } catch (error: Exception) {
                        context.contentResolver.delete(uri, null, null)
                        throw error
                    }
                } else {
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOWNLOADS), RECEIVE_DIRECTORY)
                    dir.mkdirs()
                    val target = File(dir, name)
                    try {
                        target.outputStream().use { input.copyTo(it, 64 * 1024) }
                        true
                    } catch (error: Exception) {
                        target.delete()
                        throw error
                    }
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "stream sent file failed", error)
            false
        }
    }

    /// 系统文件管理器定位（旧工程 revealReceivedFile：优先三星/谷歌文件器）。
    private fun revealReceived(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        if (name.isNullOrBlank()) {
            result.error("invalid_args", "revealReceived 需要 name", null)
            return
        }
        val state = localFileState(call.argument<String>("deliveryId"), name)
        if (state != "ready") {
            result.error(
                if (state == "pending") "not_ready" else "not_found",
                if (state == "pending") "文件仍在接收中" else "本地文件不存在", null)
            return
        }
        val safeName = safeReceiveName(name)
        val folder: Uri = try {
            DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                "primary:Download/$RECEIVE_DIRECTORY")
        } catch (error: RuntimeException) {
            Log.e(TAG, "cannot build receive folder URI", error)
            result.error("system_error", "无法定位接收文件夹", null)
            return
        }
        for (packageName in FILE_MANAGER_PACKAGES) {
            try {
                activity.startActivity(externalFolderIntent(folder, safeName).setPackage(packageName))
                result.success(safeName)
                return
            } catch (error: RuntimeException) {
                Log.d(TAG, "file manager cannot open folder: $packageName", error)
            }
        }
        try {
            activity.startActivity(externalFolderIntent(folder, safeName))
            result.success(safeName)
        } catch (error: RuntimeException) {
            Log.w(TAG, "generic external folder ACTION_VIEW rejected", error)
            result.error("system_error", "没有可用的系统文件管理器", null)
        }
    }

    private fun externalFolderIntent(folder: Uri, name: String): Intent {
        return Intent(Intent.ACTION_VIEW)
            .setDataAndType(folder, DocumentsContract.Document.MIME_TYPE_DIR)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    or Intent.FLAG_GRANT_READ_URI_PERMISSION
                    or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            .putExtra(Intent.EXTRA_TITLE, name)
    }

    /// 系统查看器打开（旧工程 viewReceivedFile：MediaStore uri + 授权）。
    private fun openReceived(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        if (name.isNullOrBlank()) {
            result.error("invalid_args", "openReceived 需要 name", null)
            return
        }
        val state = localFileState(call.argument<String>("deliveryId"), name)
        if (state != "ready") {
            result.error(
                if (state == "pending") "not_ready" else "not_found",
                if (state == "pending") "文件仍在接收中" else "本地文件不存在", null)
            return
        }
        val safeName = safeReceiveName(name)
        val mime = effectiveViewMime(safeName, call.argument<String>("mime"))
        val uri = receivedFileUri(safeName)
        if (uri == null) {
            result.error("not_found", "本地文件不存在", null)
            return
        }
        try {
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            activity.startActivity(view)
            result.success(null)
        } catch (error: RuntimeException) {
            Log.w(TAG, "no viewer for $safeName", error)
            result.error("not_found", "没有可打开该文件的应用", null)
        }
    }

    /// 本地状态（旧工程 localFileState）：ready / pending / missing。
    private fun localFileState(deliveryId: String?, name: String): String {
        val safeName = safeReceiveName(name)
        if (receivedFileExists(safeName)) return "ready"
        if (deliveryId.isNullOrEmpty()) return "missing"
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for ((key, value) in prefs.all) {
            if (!key.startsWith(PENDING_DOWNLOAD_PREFIX) || value !is String) continue
            val record = loadPendingDownload(
                key.removePrefix(PENDING_DOWNLOAD_PREFIX).toLongOrNull() ?: continue) ?: continue
            if (record.deliveryId == deliveryId) {
                if (receivedFileExists(record.name)) return "ready"
                return "pending"
            }
        }
        return "missing"
    }

    private fun receivedFileUri(name: String): Uri? {
        if (Build.VERSION.SDK_INT >= 29) {
            val relativePath = Environment.DIRECTORY_DOWNLOADS + "/" + RECEIVE_DIRECTORY + "/"
            try {
                context.contentResolver.query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    arrayOf(MediaStore.MediaColumns._ID),
                    MediaStore.MediaColumns.DISPLAY_NAME + "=? AND " +
                        MediaStore.MediaColumns.RELATIVE_PATH + "=?",
                    arrayOf(name, relativePath), null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        return ContentUris.withAppendedId(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI, cursor.getLong(0))
                    }
                }
            } catch (error: Exception) {
                Log.w(TAG, "mediastore uri lookup failed", error)
            }
            return null
        }
        val file = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "$RECEIVE_DIRECTORY/$name")
        if (!file.isFile) return null
        return FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    }

    private fun receivedFileExists(name: String): Boolean {
        if (Build.VERSION.SDK_INT >= 29) return receivedFileUri(name) != null
        return try {
            File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "$RECEIVE_DIRECTORY/$name").isFile
        } catch (error: RuntimeException) {
            Log.w(TAG, "legacy file lookup rejected", error)
            false
        }
    }

    private fun guessMime(name: String): String {
        val extension = MimeTypeMap.getFileExtensionFromUrl(name)
        if (!extension.isNullOrEmpty()) {
            MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(extension.lowercase(Locale.ROOT))?.let { return it }
        }
        return "application/octet-stream"
    }

    private fun effectiveViewMime(name: String, mime: String?): String {
        if (!mime.isNullOrEmpty() && mime != "application/octet-stream") return mime
        return guessMime(name)
    }

    private fun safeReceiveName(originalName: String): String =
        ReceiveNaming.safeName(originalName)

    private fun uniqueReceiveName(originalName: String): String =
        ReceiveNaming.uniqueName(originalName, ::receivedFileExists)

    // ----------------------------------------------------------------- update

    /// 检查更新（旧工程 checkForUpdate：GET 清单 + versionCode 比较）。
    private fun updateCheck(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("invalid_args", "update.check 需要 url", null)
            return
        }
        var connection: HttpURLConnection? = null
        try {
            connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            val json = connection.inputStream.use { input ->
                ByteArrayOutputStream().also { output -> input.copyTo(output) }.toString("UTF-8")
            }
            val manifest = JSONObject(json)
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val currentCode = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode
                else @Suppress("DEPRECATION") info.versionCode.toLong()
            val latestCode = manifest.optLong("versionCode", 0)
            result.success(mapOf(
                "current" to (info.versionName ?: currentCode.toString()),
                "latest" to manifest.optString("version", latestCode.toString()),
                "hasUpdate" to (latestCode > currentCode),
                "notes" to manifest.optString("notes", null),
                "url" to manifest.optString("url", null),
                "sha256" to manifest.optString("sha256", null),
            ))
        } catch (error: Exception) {
            Log.e(TAG, "update.check failed", error)
            result.error("system_error", error.message ?: "更新检查失败", null)
        } finally {
            connection?.disconnect()
        }
    }

    /// 下载 APK + SHA-256 校验（旧工程 downloadUpdate/finishUpdateDownload 语义；
    /// 实现用 HttpURLConnection 直接落盘到应用专属目录，完成即返回，免广播等待）。
    private fun updateDownload(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val sha256 = call.argument<String>("sha256")?.lowercase(Locale.ROOT)
        if (url.isNullOrBlank() || sha256.isNullOrBlank()) {
            result.error("invalid_args", "update.download 需要 url/sha256", null)
            return
        }
        var connection: HttpURLConnection? = null
        try {
            val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: context.filesDir
            val target = File(dir, UPDATE_APK_NAME)
            target.delete()
            connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 7000
            connection.readTimeout = 15000
            val digest = MessageDigest.getInstance("SHA-256")
            connection.inputStream.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var size: Int
                    while (input.read(buffer).also { size = it } > 0) {
                        digest.update(buffer, 0, size)
                        output.write(buffer, 0, size)
                    }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (actual != sha256) {
                target.delete()
                result.error("checksum_mismatch", "更新下载或校验失败", null)
                return
            }
            result.success(target.absolutePath)
        } catch (error: Exception) {
            Log.e(TAG, "update.download failed", error)
            result.error("system_error", error.message ?: "更新下载失败", null)
        } finally {
            connection?.disconnect()
        }
    }

    /// 发起安装（旧工程 installUpdate；FileProvider 授权）。
    /// 未允许未知来源时打开系统设置页并返回 permission_denied。
    private fun updateInstall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("invalid_args", "update.install 需要 path", null)
            return
        }
        val file = File(path)
        if (!file.isFile) {
            result.error("not_found", "安装包不存在", null)
            return
        }
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.error("permission_denied", "未允许安装未知来源应用", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                context, "${context.packageName}.fileprovider", file)
            val install = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(install)
            result.success(null)
        } catch (error: Exception) {
            Log.e(TAG, "update.install failed", error)
            result.error("system_error", error.message ?: "发起安装失败", null)
        }
    }
}
