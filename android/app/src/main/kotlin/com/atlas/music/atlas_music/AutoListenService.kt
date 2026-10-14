package com.atlas.music.atlas_music

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/// Auto Shazam-style microphone foreground service.
///
/// Started from the app while it is visible (Android only lets a *visible* app
/// start a microphone-typed service), it then keeps the microphone available
/// while the user is in other apps — so Atlas can hear a reel or a track
/// playing elsewhere without stealing the screen. The listening loop itself
/// runs in Dart; this only holds the microphone grant and shows an ongoing
/// notification.
///
/// Matches update this same notification silently ([ACTION_FOUND]) — no new
/// alert is ever posted per song.
class AutoListenService : Service() {
    private var last: String? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                IdentifyBus.channel?.invokeMethod("autoStop", null)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_FOUND -> {
                last = intent.getStringExtra(EXTRA_LAST) ?: last
                // Silent refresh of the ongoing notification (no heads-up).
                try {
                    NotificationManagerCompat.from(this)
                        .notify(LISTENING_ID, buildNotification())
                } catch (_: Exception) {
                    // Notification permission denied; nothing to show.
                }
                return START_NOT_STICKY
            }
        }
        if (!startListening()) {
            // Could not become a mic foreground service (e.g. started while not
            // eligible). Tell Dart so it stops looping, and never crash.
            IdentifyBus.channel?.invokeMethod("autoStop", null)
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    private fun startListening(): Boolean = try {
        ensureIdentifyChannel(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                LISTENING_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(LISTENING_ID, buildNotification())
        }
        true
    } catch (e: Exception) {
        Log.e(TAG, "Could not start auto-listen foreground service", e)
        false
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, AutoListenService::class.java)
            .setAction(ACTION_STOP)
        val stop = PendingIntent.getService(
            this,
            REQ_STOP,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        // Tapping the notification opens the Auto song fetch history.
        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(MainActivity.EXTRA_SHOW_HISTORY, true)
        }
        val open = PendingIntent.getActivity(
            this,
            REQ_OPEN,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, MainActivity.IDENTIFY_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(getString(R.string.auto_listening_title))
            .setContentText(last ?: getString(R.string.auto_listening_body))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, getString(R.string.auto_listening_stop), stop)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_STOP = "atlas.autolisten.stop"
        const val ACTION_FOUND = "atlas.autolisten.found"
        const val EXTRA_LAST = "atlas.autolisten.last"
        private const val TAG = "AutoListenService"
        private const val LISTENING_ID = 45
        private const val REQ_STOP = 2201
        private const val REQ_OPEN = 2202
    }
}
