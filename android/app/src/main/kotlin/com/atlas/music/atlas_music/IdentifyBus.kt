package com.atlas.music.atlas_music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodChannel

/// Process-wide hand-off between the "Identify song" Quick Settings tile and
/// the running Flutter engine.
object IdentifyBus {
    /// The Dart identify channel while the Flutter engine is alive. Null means
    /// the app is not running, so a tile tap must launch the activity.
    @Volatile
    var channel: MethodChannel? = null

    /// True once Dart has started (it calls the `consumeInitial*` methods).
    /// A recreated activity then has to *push* parked requests instead of
    /// waiting for Dart's one-shot consume.
    @Volatile
    var dartReady: Boolean = false

    /// Whether Auto-listen is running, for the tile's active state.
    @Volatile
    var autoActive: Boolean = false
}

/// Opens MainActivity with a boolean launch extra, collapsing the QS panel.
/// API 34+ requires the PendingIntent overload.
fun TileService.openMainActivity(extra: String) {
    val intent = Intent(this, MainActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        putExtra(extra, true)
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        val pending = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        startActivityAndCollapse(pending)
    } else {
        @Suppress("DEPRECATION")
        startActivityAndCollapse(intent)
    }
}

/// Creates the "Find song" notification channel if missing. Shared by the
/// result notifications.
fun ensureIdentifyChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val nm = NotificationManagerCompat.from(context)
    if (nm.getNotificationChannel(MainActivity.IDENTIFY_CHANNEL) == null) {
        nm.createNotificationChannel(
            NotificationChannel(
                MainActivity.IDENTIFY_CHANNEL,
                context.getString(R.string.identify_channel_name),
                NotificationManager.IMPORTANCE_HIGH
            )
        )
    }
}
