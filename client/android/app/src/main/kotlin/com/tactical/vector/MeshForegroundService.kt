package com.tactical.vector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the process alive so comms survive backgrounding.
 *
 * Deliberately does almost nothing itself. The relay WebSocket, P2P discovery
 * and telemetry all live in the Flutter isolate the UI already runs, and Android
 * keeps that isolate running as long as the process is not killed. So this
 * service exists only to make the process non-killable and hold a wake lock —
 * it does not host a second isolate.
 *
 * That matters: the obvious alternative (a background-isolate plugin) would mean
 * a second copy of the comms stack with its own identity, its own socket and its
 * own view of the ratchet state. Two ratchet writers for one contact would
 * desynchronise the chain.
 */
class MeshForegroundService : Service() {

    companion object {
        private const val TAG = "MeshFgService"
        private const val CHANNEL_ID = "vector_comms"
        private const val NOTIFICATION_ID = 0x5EC1

        const val ACTION_START = "com.tactical.vector.action.START_MESH"
        const val ACTION_STOP = "com.tactical.vector.action.STOP_MESH"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            // Android 14+ refuses a "location" foreground service unless the
            // location runtime permission is actually held, and Android 12+
            // refuses one started from the background at all. Either way the
            // right move is to give up quietly rather than crash the app; Dart
            // reports the failure to the operator's event log.
            Log.w(TAG, "Could not enter the foreground: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }

        acquireWakeLock()

        // NOT sticky, on purpose. If Android kills the process the Flutter
        // isolate goes with it, so a service restarted on its own would show a
        // notification claiming comms are up with nothing behind it. Better to
        // disappear honestly than to lie about being connected.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the task away is an explicit "stop" from the operator.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Vector is active")
            .setContentText("Sharing telemetry and receiving comms")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mesh comms",
            // Low: the notification has to exist for a foreground service, but it
            // is a status indicator, not an alert. Operator-facing alerts have
            // their own channels.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while Vector is transmitting telemetry and holding comms open."
            setShowBadge(false)
        }

        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    /**
     * Partial wake lock: keeps the CPU scheduled during Doze so telemetry keeps
     * going out and the relay socket's keepalive keeps answering. This is the
     * expensive part of running in the background, and it is why the service is
     * something the operator starts rather than something always on.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(PowerManager::class.java) ?: return
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "vector:mesh").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }
}
