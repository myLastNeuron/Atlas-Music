package com.atlas.music.atlas_music

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
                // Battery is requested from the permission-result callback.
                requestNotificationPermission()
            } else {
                maybeRequestBatteryExemption()
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
    }

    /// Runs the background-usage ask right after the notification dialog
    /// closes. Only reached on the first run (the only time it is requested).
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATIONS) {
            maybeRequestBatteryExemption()
        }
    }

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
        private const val REQ_NOTIFICATIONS = 1001
        private const val PREFS = "atlas_boot"
        private const val KEY_ONBOARDED = "onboarded"
    }
}
