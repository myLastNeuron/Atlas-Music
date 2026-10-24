import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../services/glass_settings.dart';
import '../services/system_permissions.dart';
import '../services/terms.dart';
import '../services/theme_settings.dart';
import '../services/user_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/liquid_background.dart';

/// Advanced settings: light mode, artwork colour in the full player, the
/// app's transparency ("glass") level, background playback, the profile name
/// and the about text.
///
/// The level lives in the theme, so moving the slider restyles every glass
/// surface in the app at once — the preview below is the real panel widget
/// over the real background, not a mock-up.
class AdvancedSettingsScreen extends StatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen>
    with WidgetsBindingObserver {
  final _prefs = UserPrefs();
  bool _batteryExempt = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBatteryStatus();
    _loadVersion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh the battery row after the user returns from the system
    // "allow background" dialog.
    if (state == AppLifecycleState.resumed) {
      _loadBatteryStatus();
    }
  }

  /// Battery-optimization status for the "Background playback" row. The
  /// exemption is auto-requested once on the first run (native, in
  /// MainActivity); this row shows the state and lets the user re-request
  /// it at any time.
  Future<void> _loadBatteryStatus() async {
    final exempt =
        await SystemPermissions.instance.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    if (exempt != _batteryExempt) {
      setState(() => _batteryExempt = exempt);
    }
  }

  /// The real installed version, so the About text can never drift from
  /// `pubspec.yaml`.
  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _version = info.version);
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset name?'),
        content: const Text('You will see the setup screen again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await _prefs.clearName();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cleared. Restart app.')),
      );
    }
  }

  /// Plain-language explanation of how the app works under the hood — no
  /// jargon, aimed at a normal listener who taps "About".
  void _showAbout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('About Atlas Music'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A free, open-source music player for Android. Your music, your '
                'library, your rules — built with Flutter.',
                style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
              ),
              const SizedBox(height: 16),
              _aboutSection(
                'Where the music comes from',
                'Atlas does not store or host any songs. When you search or play, '
                    'it looks tracks up on YouTube Music and YouTube, then streams '
                    'the audio straight to your phone.',
              ),
              _aboutSection(
                'Lyrics and translation',
                'Synced lyrics come from LRCLIB, a free public lyrics database, '
                    'and translation uses Google Translate. No sign-in needed.',
              ),
              _aboutSection(
                'Playlist import',
                'Importing a Spotify playlist uses your own free Spotify API '
                    'keys. They are saved only on this device.',
              ),
              _aboutSection(
                'Your data stays with you',
                'There are no accounts and no cloud sync. Your playlists, likes, '
                    'history and settings never leave your phone. Downloads are '
                    'kept on-device, capped at 1 GB and cleared after 30 days.',
              ),
              Text(
                'Version ${_version.isEmpty ? '…' : _version} · Developed by myLastNeuron · Apache 2.0 license',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// The same terms the first-launch gate shows, readable at any time.
  void _showTerms() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(kTermsTitle),
        content: SingleChildScrollView(
          child: Text(kTermsBody,
              style: TextStyle(fontSize: 13, color: AppColors.inkSoft)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _aboutSection(String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(body,
              style: TextStyle(fontSize: 12.5, color: AppColors.inkSoft)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = glassSettings(context);
    final level = settings?.level ?? GlassSettings.defaultLevel;
    return LiquidBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: AppColors.ink),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text('Advanced settings',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: AppColors.ink)),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              shape: kRowPressShape,
              value: context.watch<ThemeSettings>().isLight,
              onChanged: (v) => context.read<ThemeSettings>().setLight(v),
              secondary: Icon(
                AppColors.isLight ? Icons.light_mode : Icons.dark_mode,
                size: 20,
                color: AppColors.inkSoft,
              ),
              title: const Text('Light mode',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              subtitle: Text(
                'Paper background with dark text. Off is the dark glass look.',
                style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
              ),
            ),
            Divider(height: 1, color: AppColors.line),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              shape: kRowPressShape,
              value: context.watch<ThemeSettings>().artworkColor,
              onChanged: (v) => context.read<ThemeSettings>().setArtworkColor(v),
              secondary: Icon(Icons.palette_outlined,
                  size: 20, color: AppColors.inkSoft),
              title: const Text('Artwork colour in player',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              subtitle: Text(
                'The full player takes its colour from the current song’s '
                'artwork. Nothing else changes.',
                style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
              ),
            ),
            Divider(height: 24, color: AppColors.line),
            Text('Transparency',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink)),
            const SizedBox(height: 4),
            Text(
              'How much of the background shows through the app surfaces: the '
              'mini player, the sheets and the panels.',
              style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
            ),
            const SizedBox(height: 12),
            const GlassPreview(),
            const SizedBox(height: 14),
            Slider(
              value: level,
              min: 0,
              max: 1,
              label: '${(level * 100).round()}%',
              onChanged: (v) => settings?.setLevel(v),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Transparent',
                    style: TextStyle(fontSize: 12, color: AppColors.mute)),
                Text('Translucent',
                    style: TextStyle(fontSize: 12, color: AppColors.mute)),
              ],
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => settings?.setLevel(GlassSettings.defaultLevel),
              child: const Text('Reset to default'),
            ),
            const SizedBox(height: 24),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: Icon(
                        _batteryExempt
                            ? Icons.battery_full
                            : Icons.battery_saver_outlined,
                        size: 20,
                        color: _batteryExempt ? AppColors.ink : AppColors.mute,
                      ),
                      title: const Text('Background playback',
                          style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                          _batteryExempt
                              ? 'Optimized — battery unrestricted'
                              : 'Tap to allow unrestricted background',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      trailing: Icon(
                        _batteryExempt
                            ? Icons.check_circle
                            : Icons.chevron_right,
                        size: 18,
                        color: _batteryExempt ? AppColors.ink : AppColors.mute,
                      ),
                      onTap: () async {
                        if (_batteryExempt) return;
                        await SystemPermissions.instance
                            .requestBatteryExemption();
                        await _loadBatteryStatus();
                      },
                    ),
                  ),
                  Divider(height: 1, color: AppColors.line),
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.refresh, size: 20),
                      title: const Text('Reset name',
                          style: TextStyle(fontSize: 14)),
                      trailing: Icon(Icons.chevron_right,
                          color: AppColors.mute),
                      onTap: _reset,
                    ),
                  ),
                  Divider(height: 1, color: AppColors.line),
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.description_outlined, size: 20),
                      title: const Text('Terms and Conditions',
                          style: TextStyle(fontSize: 14)),
                      trailing: Icon(Icons.chevron_right,
                          color: AppColors.mute),
                      onTap: _showTerms,
                    ),
                  ),
                  Divider(height: 1, color: AppColors.line),
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.info_outline, size: 20),
                      title:
                          const Text('About', style: TextStyle(fontSize: 14)),
                      subtitle: Text(_version.isEmpty ? '' : 'v$_version',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      trailing: Icon(Icons.chevron_right,
                          color: AppColors.mute),
                      onTap: _showAbout,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slice of the real UI — the same glass panel, over a stand-in for album
/// art. Artwork is the backdrop transparency is judged against, so both ends
/// of the slider are visible right there. Sized to its own box, never clipped.
class GlassPreview extends StatelessWidget {
  const GlassPreview({super.key});

  static const _art = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF23232D), Color(0xFF3A2E48), Color(0xFF563F33)],
  );

  static const _thumb = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6C5A86), Color(0xFF9A7356)],
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 176,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: _art,
            ),
            child: const Icon(Icons.graphic_eq,
                size: 96, color: Color(0x1FFFFFFF)),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: GlassPanel(
                radius: 22,
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: _thumb,
                          ),
                          child: const Icon(Icons.music_note,
                              size: 24, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Midnight Drive',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.ink)),
                              const SizedBox(height: 2),
                              Text('Atlas Radio · Now playing',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12, color: AppColors.inkSoft)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.action,
                          ),
                          child: Icon(Icons.pause,
                              size: 20, color: AppColors.charcoal),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: 0.42,
                        minHeight: 3,
                        backgroundColor: AppColors.ink.withValues(alpha: 0.16),
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppColors.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
