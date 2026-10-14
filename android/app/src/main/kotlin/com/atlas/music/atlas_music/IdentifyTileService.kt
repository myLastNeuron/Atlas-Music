package com.atlas.music.atlas_music

import android.service.quicksettings.TileService

/// "Find song" Quick Settings tile.
///
/// Android grants the microphone only to a *visible* app (there is no "always
/// allow" for the mic) and silences capture from the background, so the tile
/// opens Atlas straight onto the Find-song sheet — the same way Shazam listens
/// — instead of recording silence and matching nothing.
class IdentifyTileService : TileService() {
    override fun onClick() {
        super.onClick()
        openMainActivity(MainActivity.EXTRA_IDENTIFY)
    }
}
