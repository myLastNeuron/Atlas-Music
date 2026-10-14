package com.atlas.music.atlas_music

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var identifyChannel: MethodChannel? = null
    private var pendingIdentify = false

    /// A notification tap / launcher shortcut that launched the activity while
    /// it was not alive; Dart picks them up with the `consumeInitial*` calls.
    private var pendingShowHistory = false
    private var pendingAutoStart = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // These launch extras are parked for Dart, then cleared so an activity
        // recreate (rotation / process restore) cannot re-trigger the flow.
        pendingIdentify = flag(intent, EXTRA_IDENTIFY)
        pendingShowHistory = flag(intent, EXTRA_SHOW_HISTORY)
        pendingAutoStart = flag(intent, EXTRA_AUTO_START)
        intent?.removeExtra(EXTRA_IDENTIFY)
        intent?.removeExtra(EXTRA_SHOW_HISTORY)
        intent?.removeExtra(EXTRA_AUTO_START)
        // First-run setup, once per install and never on the playback path so
        // starting music is never interrupted by a dialog:
        //  1. Notification permission (Android 13+) — a normal runtime ask.
        //  2. "Allow background usage" (battery-optimization exemption).
        //     Android cannot grant this silently, so the app auto-opens the
        //     system dialog for the user. It is chained behind the
        //     notification ask (see onRequestPermissionsResult) so the two
        //     dialogs never stack on top of each other. Users can still change
        //     it later from Profile. Background playback reliability itself
        //     comes from the foreground service + wakelocks + the offline
        //     self-heal in Dart.
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ONBOARDED, false)) {
            prefs.edit().putBoolean(KEY_ONBOARDED, true).apply()
            if (needsNotificationAsk()) {
                // Mic + battery are requested from the permission-result callback.
                requestNotificationPermission()
            } else {
                startMicThenBattery()
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestBatteryExemption" -> {
                        maybeRequestBatteryExemption()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        identifyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            IDENTIFY_CHANNEL
        )
        identifyChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Cold start: Dart asks once for a tile tap that launched us.
                "consumeInitialIdentify" -> {
                    IdentifyBus.dartReady = true
                    val pending = pendingIdentify
                    pendingIdentify = false
                    result.success(pending)
                }
                // Cold start: Dart asks once for a notification tap / shortcut.
                "consumeInitialShowHistory" -> {
                    IdentifyBus.dartReady = true
                    val pending = pendingShowHistory
                    pendingShowHistory = false
                    result.success(pending)
                }
                "consumeInitialAutoStart" -> {
                    IdentifyBus.dartReady = true
                    val pending = pendingAutoStart
                    pendingAutoStart = false
                    result.success(pending)
                }
                // Auto-listen: a mic-typed foreground service started while the
                // app is visible, so Atlas can keep listening in the background.
                "startAutoListen" -> {
                    try {
                        ContextCompat.startForegroundService(
                            applicationContext,
                            Intent(applicationContext, AutoListenService::class.java)
                        )
                        result.success(true)
                    } catch (_: Exception) {
                        // Refused (e.g. started while not eligible).
                        result.success(false)
                    }
                }
                "stopAutoListen" -> {
                    try {
                        stopService(Intent(applicationContext, AutoListenService::class.java))
                    } catch (_: Exception) {
                        // Nothing to stop.
                    }
                    result.success(null)
                }
                // A new Auto-listen match: silently update the ongoing
                // notification (never a new alert). History is updated in Dart.
                "autoFound" -> {
                    try {
                        startService(
                            Intent(applicationContext, AutoListenService::class.java)
                                .setAction(AutoListenService.ACTION_FOUND)
                                .putExtra(
                                    AutoListenService.EXTRA_LAST,
                                    call.arguments as? String
                                )
                        )
                    } catch (_: Exception) {
                        // Service gone; nothing to update.
                    }
                    result.success(null)
                }
                // Auto-listen state, so the Quick Settings tile can show it.
                "autoActive" -> {
                    IdentifyBus.autoActive = (call.arguments as? Boolean) ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        TileService.requestListeningState(
                            applicationContext,
                            ComponentName(applicationContext, AutoListenTileService::class.java)
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Lets the Quick Settings tile hand an identify request to Dart without
        // launching this activity.
        IdentifyBus.channel = identifyChannel
        // If Dart is already running (the activity was recreated), its one-shot
        // consume will not run again — push any parked request instead.
        if (IdentifyBus.dartReady) {
            Handler(Looper.getMainLooper()).post { pushPending() }
        }
    }

    /// Hands parked launch requests to the already-running Dart instance.
    private fun pushPending() {
        if (pendingIdentify) {
            pendingIdentify = false
            identifyChannel?.invokeMethod("identify", null)
        }
        if (pendingShowHistory) {
            pendingShowHistory = false
            identifyChannel?.invokeMethod("showHistory", null)
        }
        if (pendingAutoStart) {
            pendingAutoStart = false
            identifyChannel?.invokeMethod("autoStart", null)
        }
    }

    /// The app was already running (singleTop) and something re-launched it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val isIdentify = flag(intent, EXTRA_IDENTIFY)
        val showHistory = flag(intent, EXTRA_SHOW_HISTORY)
        val autoStart = flag(intent, EXTRA_AUTO_START)
        intent.removeExtra(EXTRA_IDENTIFY)
        intent.removeExtra(EXTRA_SHOW_HISTORY)
        intent.removeExtra(EXTRA_AUTO_START)
        setIntent(intent)
        if (isIdentify) identifyChannel?.invokeMethod("identify", null)
        if (showHistory) identifyChannel?.invokeMethod("showHistory", null)
        if (autoStart) identifyChannel?.invokeMethod("autoStart", null)
    }

    /// A launch extra can arrive as a boolean or a string (shortcut XML stores
    /// strings), so accept either.
    private fun flag(intent: Intent?, key: String): Boolean =
        intent?.getBooleanExtra(key, false) == true ||
            intent?.getStringExtra(key) == "true"

    /// Runs the background-usage ask right after the permission dialogs close.
    /// Only reached on the first run (the only time they are requested).
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Guard on the permission, not just the code: request codes are
        // process-wide and `record` also uses 1001 for RECORD_AUDIO. Matching
        // only on the code popped the battery dialog when the mic was granted.
        if (requestCode == REQ_NOTIFICATIONS &&
            permissions.contains(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            // The mic is what lets "Identify song" record from the tile while
            // the app is backgrounded, so ask for it here rather than only when
            // the user first opens the identify sheet. Always continue the
            // chain: a denied notification dialog is gone, so the mic ask
            // cannot stack on it, and the mic must be pre-granted for the very
            // first "Find song" tap to record.
            startMicThenBattery()
        } else if (requestCode == REQ_MIC &&
            permissions.contains(Manifest.permission.RECORD_AUDIO)
        ) {
            maybeRequestBatteryExemption()
        }
    }

    /// Next first-run ask after notifications: the mic, then the battery
    /// exemption. Chained so the two dialogs never stack.
    private fun startMicThenBattery() {
        if (needsMicAsk()) requestMicPermission() else maybeRequestBatteryExemption()
    }

    private fun needsMicAsk(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED

    private fun requestMicPermission() {
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
    }

    // ---- Permissions / battery ------------------------------------------

    private fun needsNotificationAsk(): Boolean =
        Build.VERSION.SDK_INT >= 33 && !hasNotificationPermission()

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /// Opens the system "allow this app to run in the background" dialog.
    /// Called automatically on first run and from an explicit tap in Profile.
    private fun maybeRequestBatteryExemption() {
        if (isIgnoringBatteryOptimizations()) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
        } catch (_: Exception) {
            // Some ROMs block the direct intent; fall back to the settings list.
            try {
                startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                )
            } catch (_: Exception) {
                // Give up silently — the exemption stays optional.
            }
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        if (hasNotificationPermission()) return
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFICATIONS
        )
    }

    companion object {
        private const val CHANNEL = "atlas/permissions"

        /// Notification channel id, shared with the Auto-listen notifications.
        internal const val IDENTIFY_CHANNEL = "atlas/identify"

        /// Set by IdentifyTileService when the Quick Settings tile is tapped.
        const val EXTRA_IDENTIFY = "atlas.identify"

        /// Carried by a notification tap: open the Auto song fetch history.
        const val EXTRA_SHOW_HISTORY = "atlas.showHistory"

        /// Carried by the "Auto listen" shortcut / tile.
        const val EXTRA_AUTO_START = "atlas.autoStart"

        // Must NOT collide with record_android's RECORD_AUDIO request code
        // (1001): a shared code mixed the two permission results up.
        private const val REQ_NOTIFICATIONS = 2001
        private const val REQ_MIC = 2003
        private const val PREFS = "atlas_boot"
        private const val KEY_ONBOARDED = "onboarded"
    }
}
