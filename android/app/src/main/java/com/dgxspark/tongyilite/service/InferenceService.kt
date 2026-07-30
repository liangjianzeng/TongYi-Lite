/**
 * Foreground Service for inference keep-alive.
 *
 * Android 8+ aggressively kills background services.
 * A foreground service with a persistent notification is the
 * only reliable way to keep long inference runs alive when
 * the user switches to another app.
 */

package com.dgxspark.tongyilite.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.dgxspark.tongyilite.R

class InferenceService : Service() {

    companion object {
        private const val TAG = "InferenceService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "inference_channel"

        fun start(context: Context) {
            val intent = Intent(context, InferenceService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, InferenceService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("TongYi-Lite 就绪"))
        Log.i(TAG, "Foreground service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val status = intent?.getStringExtra("status") ?: "推理中..."
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(status))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIFICATION_ID)
        Log.i(TAG, "Foreground service stopped")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "AI 推理服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持 AI 推理在后台运行"
                setShowBadge(false)
            }
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("TongYi-Lite")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .build()
    }
}
