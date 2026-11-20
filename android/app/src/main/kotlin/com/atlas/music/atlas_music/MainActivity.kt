package com.atlas.music.atlas_music

import android.Manifest
import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var identifyChannel: MethodChannel? = null
    /// Pending backup answers: the storage-permission prompt and the file
    /// picker both finish after their system UI closes, and this Activity can
    /// be recreated while the Dart caller is still waiting. Backed by
    /// process-scoped fields for the same reason the launch flags below are:
    /// in an instance field the answer was lost, the channel call never
    /// returned, and the Settings row spun until the screen was left.
    private var pendingStorageResult: MethodChannel.Result?
        get() = pendingStorageResultRef
        set(value) { pendingStorageResultRef = value }
    private var pendingPickResult: MethodChannel.Result?
        get() = pendingPickResultRef
        set(value) { pendingPickResultRef = value }

    /// Launch requests parked for Dart, backed by process-scoped flags: a
    /// rotation (or process restore) recreates the Activity before Dart's
    /// one-shot consumeInitial* call, and instance fields would drop the
    /// request on the way. Dart picks them up with the `consumeInitial*` calls.
    private var pendingIdentify: Boolean
        get() = pendingIdentifyFlag
        set(value) { pendingIdentifyFlag = value }
    private var pendingShowHistory: Boolean
        get() = pendingShowHistoryFlag
        set(value) { pendingShowHistoryFlag = value }
    private var pendingAutoStart: Boolean
        get() = pendingAutoStartFlag
        set(value) { pendingAutoStartFlag = value }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // These launch extras are parked for Dart, then cleared so an activity
        // recreate (rotation / process restore) cannot re-trigger the flow.
        // OR with whatever was parked before a recreate.
        if (flag(intent, EXTRA_IDENTIFY)) pendingIdentify = true
        if (flag(intent, EXTRA_SHOW_HISTORY)) pendingShowHistory = true
        if (flag(intent, EXTRA_AUTO_START)) pendingAutoStart = true
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

    override fun onResume() {
        super.onResume()
        // Without this the window sits on the platform's 60 Hz default even on
        // a 90/120/144 Hz panel (measured: launcher 90, Atlas 60 on a edge 70
        // fusion), so the player's card and cover move in coarse steps next to
        // every system animation. Ask for the panel's peak mode; ROMs that
        // refuse the hint simply keep their default.
        try {
            val d = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                windowManager.defaultDisplay
            }
            val modes = d?.supportedModes ?: return
            val current = d.mode
            val sameResolution = modes.filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            val panelPeak =
                sameResolution.maxByOrNull { it.refreshRate } ?: return
            // Never exceed the user's own cap (Settings > Display > refresh
            // rate): some ROMs store it, and blowing past it is a battery
            // regression the user did not ask for.
            val systemCap = try {
                Settings.System.getString(
                    contentResolver,
                    "peak_refresh_rate"
                )?.toFloatOrNull()
            } catch (_: Exception) {
                null
            }
            val target = if (systemCap != null && systemCap > 30f) {
                minOf(systemCap, panelPeak.refreshRate)
            } else {
                panelPeak.refreshRate
            }
            val mode = sameResolution
                .filter { it.refreshRate <= target + 0.01f }
                .maxByOrNull { it.refreshRate } ?: panelPeak
            val attrs = window.attributes
            attrs.preferredDisplayModeId = mode.modeId
            window.attributes = attrs
        } catch (_: Exception) {
            // Refresh-rate hints are advisory; 60 Hz is still correct.
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
                    // In-app updater: the user taps "Update", Dart downloads
                    // the APK and asks native to hand it to the installer.
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        result.success(path != null && installApk(path))
                    }
                    // Revert list: open the picked version's release page.
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        result.success(url != null && openUrl(url))
                    }
                    // Backup export/import: save a .json into Downloads and
                    // read one back with the system file picker.
                    "requestStoragePermission" -> requestStoragePermission(result)
                    "saveToDownloads" -> {
                        val filename = call.argument<String>("filename")
                        val content = call.argument<String>("content")
                        result.success(
                            if (filename == null || content == null) null
                            else saveToDownloads(filename, content)
                        )
                    }
                    "pickJsonFile" -> pickJsonFile(result)
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
        if (requestCode == REQ_STORAGE) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingStorageResult?.success(granted)
            pendingStorageResult = null
        }
    }

    /// Backs the import flow's file picker. The document is read on a
    /// background thread because a cloud provider can be slow, and the read
    /// stops at the cap even when the provider reports no length.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_JSON) return
        val result = pendingPickResult
        pendingPickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result?.success(null)
            return
        }
        Thread {
            try {
                val text = readPickedFile(uri)
                runOnUiThread { result?.success(text) }
            } catch (_: TooLargeException) {
                runOnUiThread {
                    result?.error(
                        "too_large",
                        "That backup file is too large.",
                        null
                    )
                }
            } catch (_: Exception) {
                runOnUiThread {
                    result?.error(
                        "read_failed",
                        "Could not read that file.",
                        null
                    )
                }
            }
        }.start()
    }

    /// The Activity is going away for good, not being recreated — a recreation
    /// keeps the process-scoped answers, and the picker result is delivered to
    /// the new instance. Answering here means the Dart future never hangs and
    /// the Settings row stops spinning.
    override fun onDestroy() {
        if (isFinishing) {
            pendingStorageResult?.success(false)
            pendingStorageResult = null
            pendingPickResult?.success(null)
            pendingPickResult = null
        }
        super.onDestroy()
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

    // ---- Backup export / import ------------------------------------------

    /// Android 10+ writes to Downloads with no permission; Android 7-9 needs
    /// the storage grant. Asked here, answered when the system dialog closes.
    private fun hasWritePermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestStoragePermission(result: MethodChannel.Result) {
        if (hasWritePermission()) {
            result.success(true)
            return
        }
        if (pendingStorageResult != null) {
            result.success(false)
            return
        }
        pendingStorageResult = result
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            REQ_STORAGE
        )
    }

    /// Writes the backup into the public Downloads folder. Returns the saved
    /// file name, or null when the write failed.
    private fun saveToDownloads(filename: String, content: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                ) ?: return null
                try {
                    contentResolver.openOutputStream(uri)?.use {
                        it.write(content.toByteArray(Charsets.UTF_8))
                    } ?: throw IllegalStateException("no output stream")
                    contentResolver.update(
                        uri,
                        ContentValues().apply {
                            put(MediaStore.MediaColumns.IS_PENDING, 0)
                        },
                        null,
                        null
                    )
                } catch (_: Exception) {
                    // Do not leave an invisible pending row behind.
                    contentResolver.delete(uri, null, null)
                    return null
                }
                // MediaStore may add " (1)" to a same-name file, so report the
                // name it actually used.
                try {
                    contentResolver.query(
                        uri,
                        arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                        null,
                        null,
                        null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val name = cursor.getString(0)
                            if (!name.isNullOrEmpty()) return name
                        }
                    }
                } catch (_: Exception) {
                    // The file is written; the requested name is good enough.
                }
                filename
            } else {
                if (!hasWritePermission()) return null
                val dir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                )
                if (!dir.exists() && !dir.mkdirs()) return null
                val file = uniqueFile(dir, filename)
                file.writeText(content, Charsets.UTF_8)
                // The Downloads app only lists indexed files.
                MediaScannerConnection.scanFile(
                    this, arrayOf(file.absolutePath),
                    arrayOf("application/json"), null
                )
                file.name
            }
        } catch (_: Exception) {
            null
        }
    }

    /// Reads the picked document, refusing anything over the cap even when the
    /// provider reports an unknown length (-1).
    private fun readPickedFile(uri: Uri): String {
        val declared = contentResolver.openAssetFileDescriptor(uri, "r")
            ?.use { it.length } ?: -1L
        if (declared > MAX_BACKUP_BYTES) throw TooLargeException()
        val out = StringBuilder()
        contentResolver.openInputStream(uri)?.bufferedReader()?.use { reader ->
            val buffer = CharArray(16 * 1024)
            while (true) {
                val read = reader.read(buffer)
                if (read < 0) break
                out.append(buffer, 0, read)
                if (out.length.toLong() > MAX_BACKUP_BYTES) {
                    throw TooLargeException()
                }
            }
        } ?: throw IllegalStateException("no input stream")
        return out.toString()
    }

    private class TooLargeException : Exception()

    /// Never overwrite an earlier backup on Android 7-9.
    private fun uniqueFile(dir: File, name: String): File {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var file = File(dir, name)
        var n = 1
        while (file.exists()) {
            file = File(dir, "$base $n$ext")
            n++
        }
        return file
    }

    /// Providers label the same .json as application/json, text/plain or
    /// application/octet-stream, so all three are offered; the content is
    /// validated on the Dart side.
    private fun pickJsonFile(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.success(null)
            return
        }
        pendingPickResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf(
                        "application/json",
                        "text/plain",
                        "application/octet-stream"
                    )
                )
            }
            startActivityForResult(intent, REQ_PICK_JSON)
        } catch (_: Exception) {
            pendingPickResult = null
            result.success(null)
        }
    }

    // ---- In-app updater --------------------------------------------------

    /// Android 8.0+ gates the package installer behind a per-app "install
    /// unknown apps" allowance; earlier versions install freely.
    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    /// Opens the system "install unknown apps" screen for Atlas so the user can
    /// grant the permission the installer needs.
    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
        } catch (_: Exception) {
            // Some ROMs block the package-scoped intent; fall back to the list.
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES))
            } catch (_: Exception) {
                // Give up silently — the updater shows a message either way.
            }
        }
    }

    /// Hands a downloaded APK to the system package installer. A content:// URI
    /// from the FileProvider is required: a raw file:// is rejected on API 24+.
    private fun installApk(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(
                this, "${packageName}.fileprovider", file
            )
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /// Opens an http(s) link in the browser. The revert list uses it to reach
    /// the exact release page for the version the user picked.
    private fun openUrl(url: String): Boolean {
        return try {
            val uri = Uri.parse(url)
            if (uri.scheme != "https" && uri.scheme != "http") return false
            startActivity(
                Intent(Intent.ACTION_VIEW, uri)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (_: Exception) {
            false
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
        // Process-scoped request flags (see the pending* properties above).
        private var pendingIdentifyFlag = false
        private var pendingShowHistoryFlag = false
        private var pendingAutoStartFlag = false

        /// Answers parked for system UI (see the pending* properties above).
        /// Process-scoped so a recreated Activity still resolves them.
        private var pendingStorageResultRef: MethodChannel.Result? = null
        private var pendingPickResultRef: MethodChannel.Result? = null

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
        private const val REQ_STORAGE = 2005
        private const val REQ_PICK_JSON = 2006

        /// A backup is a few hundred KB at most; anything bigger is not an
        /// Atlas backup and is not read into memory.
        private const val MAX_BACKUP_BYTES = 20L * 1024 * 1024
        private const val PREFS = "atlas_boot"
        private const val KEY_ONBOARDED = "onboarded"
    }
}
