package xyz.copysync.copysync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/// 前台保活服务（迁移自旧工程 SyncService）：只负责服务生命周期与常驻通知；
/// SSE/同步循环在 Dart 侧，原生不轮询。mode：realtime / saving（文案不同），
/// off 等价于停止（Dart 侧调用 background.stop，不经过本服务）。
class SyncService : Service() {
    companion object {
        const val CHANNEL = "copysync_receiver"
        const val NOTIFY_ID = 41
        const val PREFS = "copysync"
        const val SYNC_MODE = "sync_mode"
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        var mode = intent?.getStringExtra("mode")
        if (mode == null) mode = prefs.getString(SYNC_MODE, "realtime")
        if (mode == "off") {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        prefs.edit().putString(SYNC_MODE, mode).apply()
        startForeground(NOTIFY_ID, statusNotification(mode))
        return START_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun statusNotification(mode: String?): Notification {
        val open = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val action = PendingIntent.getActivity(
            this, NOTIFY_ID, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val text = if (mode == "saving") "节能模式 · 同步频率降低" else "实时模式 · 保持跨设备同步"
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("CopySync 后台同步")
            .setContentText(text)
            .setContentIntent(action)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(CHANNEL, "CopySync 后台接收", NotificationManager.IMPORTANCE_LOW)
        channel.description = "保持跨设备内容接收"
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }
}
