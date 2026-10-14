package com.atlas.music.atlas_music

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/// "Auto listen" Quick Settings tile — a notification-panel control that turns
/// Auto-listen on or off.
///
/// Starting needs a *visible* app (Android releases the microphone only to a
/// visible app), so an inactive tap opens Atlas with the auto-start flag; an
/// active tap stops listening immediately, which needs no activity.
class AutoListenTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        if (IdentifyBus.autoActive) {
            IdentifyBus.channel?.invokeMethod("autoStop", null)
            stopService(Intent(this, AutoListenService::class.java))
            IdentifyBus.autoActive = false
            refresh()
            return
        }
        openMainActivity(MainActivity.EXTRA_AUTO_START)
    }

    private fun refresh() {
        qsTile?.apply {
            state = if (IdentifyBus.autoActive) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            updateTile()
        }
    }
}
