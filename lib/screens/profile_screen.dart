import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../services/storage_service.dart';
import '../services/system_permissions.dart';
import '../services/user_prefs.dart';
import '../services/spotify_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/liquid_background.dart';
import 'liked_songs_screen.dart';

/// Settings + identity. Name edit persists and reflects in header.
class ProfileScreen extends StatefulWidget {
  final String userName;
  const ProfileScreen({super.key, required this.userName});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver {
  final _prefs = UserPrefs();
  final _storage = StorageService();
  String _name = '';
  String? _avatarUrl;
  int _liked = 0;
  int _playlists = 0;
  int _recent = 0;
  bool _batteryExempt = false;
  bool _spotifyLinked = false;
  String? _spotifyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _name = widget.userName;
    _storage.addListener(_onStorageChanged);
    _loadStats();
    _loadSpotify();
    _loadBatteryStatus();
  }

  void _onStorageChanged() {
    if (!mounted) return;
    _loadStats();
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

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh the battery-exemption row after the user returns from the
    // system "allow background" dialog.
    if (state == AppLifecycleState.resumed) {
      _loadBatteryStatus();
    }
  }

  /// Same shared avatar as the home header: standalone read with its own
  /// guard, so a corrupt stats entry can never blank the photo here
  /// while Home still shows it (or vice versa).
  bool _avatarError = false;
  Future<void> _refreshAvatar() async {
    try {
      final avatar = await _prefs.getAvatar();
      if (!mounted) return;
      if (avatar != _avatarUrl) {
        setState(() {
          _avatarUrl = avatar;
          _avatarError = false;
        });
      }
    } catch (_) {}
  }

  Future<void> _changeAvatar() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await picked.saveTo(file.path);
      await _prefs.setAvatar(file.path);
      await _refreshAvatar();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update profile photo')),
      );
    }
  }

  Future<void> _loadStats() async {
    await _refreshAvatar();
    try {
      final l = await _storage.getLikedSongs();
      final p = await _storage.getPlaylists();
      final r = await _storage.getRecentlyPlayed();
      if (!mounted) return;
      // Storage notifies on every play tick: rebuild only when something
      // actually changed so the screen never janks while music plays.
      if (l.length == _liked && p.length == _playlists && r.length == _recent) {
        return;
      }
      setState(() {
        _liked = l.length;
        _playlists = p.length;
        _recent = r.length;
      });
    } catch (_) {}
  }

  Future<void> _loadSpotify() async {
    try {
      final sp = SpotifyService();
      final linked = await sp.hasCredentials();
      final id = linked ? await sp.getClientId() : null;
      if (!mounted) return;
      if (linked == _spotifyLinked && id == _spotifyId) return;
      setState(() {
        _spotifyLinked = linked;
        _spotifyId = id;
      });
    } catch (_) {}
  }

  /// Spotify Client ID/Secret editor. Keys stay on-device; no premium
  /// needed — a free app at developer.spotify.com/dashboard works.
  Future<void> _spotifyKeys() async {
    final sp = SpotifyService();
    final existing = await sp.getClientId();
    final idCtrl = TextEditingController(text: existing ?? '');
    final secretCtrl = TextEditingController();
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Spotify keys'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Free app at developer.spotify.com/dashboard → Create app. No premium needed. Keys never leave this device.',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: idCtrl,
                decoration: const InputDecoration(
                    hintText: 'Client ID', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secretCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    hintText: 'Client Secret (leave blank to keep)',
                    border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'clear'),
              child: const Text('Clear', style: TextStyle(color: Colors.red))),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Save')),
        ],
      ),
    );
    final id = idCtrl.text;
    final secret = secretCtrl.text;
    idCtrl.dispose();
    secretCtrl.dispose();
    if (action == 'clear') {
      await sp.clearCredentials();
      if (!mounted) return;
      setState(() {
        _spotifyLinked = false;
        _spotifyId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Spotify keys removed')),
      );
      return;
    }
    if (action != 'save' || id.trim().isEmpty) return;
    if (secret.trim().isEmpty) {
      // Secret unreadable once saved: blank means keep — valid only
      // when the ID is unchanged and keys already exist.
      final unchanged = existing != null && id.trim() == existing;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(unchanged
                ? 'Spotify keys unchanged'
                : 'Client Secret required')),
      );
      return;
    }
    await sp.saveCredentials(id, secret);
    await _loadSpotify();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Spotify keys saved')),
    );
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _name);
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Change name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              hintText: 'Your name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    await _prefs.setName(v);
    if (!mounted) return;
    setState(() => _name = v);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Name updated. Restart to see flight again.')),
    );
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
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

  @override
  Widget build(BuildContext context) {
    final initial = _name.isNotEmpty ? _name.trim()[0].toUpperCase() : '?';
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding:
              const EdgeInsets.only(left: 20, right: 20, top: 14, bottom: 190),
          children: [
            const Text('Profile',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(18),
              opacity: 0.09,
              blur: 0,
              child: Row(
                children: [
                  MotionPress(
                    scale: 0.96,
                    child: GestureDetector(
                      onTap: _changeAvatar,
                      child: Semantics(
                        button: true,
                        label: 'Change profile photo',
                        child: SizedBox(
                          width: 62,
                          height: 62,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              CircleAvatar(
                                radius: 31,
                                backgroundColor: AppColors.mist,
                                backgroundImage: _avatarUrl != null
                                    ? (_avatarUrl!.startsWith('http')
                                        ? NetworkImage(_avatarUrl!)
                                        : FileImage(File(_avatarUrl!))
                                            as ImageProvider)
                                    : null,
                                onBackgroundImageError: (_, __) {
                                  if (mounted && !_avatarError) {
                                    setState(() => _avatarError = true);
                                  }
                                },
                                child: (_avatarUrl == null || _avatarError)
                                    ? Text(initial,
                                        style: const TextStyle(
                                            fontSize: 26,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white))
                                    : null,
                              ),
                              Positioned(
                                right: -1,
                                bottom: -1,
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: AppColors.charcoal,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: AppColors.glassBorder),
                                  ),
                                  child: const Icon(Icons.photo_camera,
                                      size: 12, color: AppColors.ink),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        Text('$_playlists playlists · $_liked liked',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.inkSoft)),
                        TextButton.icon(
                          onPressed: _changeAvatar,
                          icon: const Icon(Icons.photo_camera, size: 15),
                          label: const Text('Change photo'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            alignment: Alignment.centerLeft,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(onPressed: _rename, child: const Text('Edit')),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Stagger(
              index: 1,
              child: Row(
                children: [
                  _stat('$_recent', 'Recent'),
                  const SizedBox(width: 10),
                  _stat('$_liked', 'Liked', onTap: _openLiked),
                  const SizedBox(width: 10),
                  _stat('$_playlists', 'Playlists'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              opacity: 0.07,
              blur: 0,
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
                          style: const TextStyle(
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
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              opacity: 0.07,
              blur: 0,
              child: Column(
                children: [
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.music_note_outlined, size: 20),
                      title:
                          const Text('Spotify', style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                          _spotifyLinked
                              ? 'Keys saved${_spotifyId != null ? ' · ${_spotifyId!.length > 6 ? '${_spotifyId!.substring(0, 6)}…' : _spotifyId}' : ''} — tap to update'
                              : 'Add keys to enable playlist clone',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      trailing: Icon(
                          _spotifyLinked
                              ? Icons.check_circle
                              : Icons.chevron_right,
                          color:
                              _spotifyLinked ? Colors.white : AppColors.mute),
                      onTap: _spotifyKeys,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              opacity: 0.07,
              blur: 0,
              child: Column(
                children: [
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.refresh, size: 20),
                      title: const Text('Reset name',
                          style: TextStyle(fontSize: 14)),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppColors.mute),
                      onTap: _reset,
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.info_outline, size: 20),
                      title:
                          const Text('About', style: TextStyle(fontSize: 14)),
                      subtitle: const Text('v1.0.1',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            backgroundColor: AppColors.card,
                            title: const Text('About Atlas Music'),
                            content: const SingleChildScrollView(
                              child: Text(
                                'Atlas Music is a music discovery app.\n\n'
                                'What we do:\n'
                                '• Discover songs via YouTube search with heuristic filters.\n'
                                '• Show Popular and Recommended sections based on your listening history.\n'
                                '• Play audio streams with ExoPlayer via youtube_explode_dart (YouTube only).\n\n'
                                'How backend works:\n'
                                '• Discovery: YouTube search + filters for official/title song, duration 60-420s, bad phrase blacklist.\n'
                                '• Playback: MediaResolver uses YouTubeProvider with VisionOS client to avoid throttling.\n'
                                '• Data: Local SharedPreferences for playlists, history, search history. No cloud account needed.\n'
                                '• Offline: Audio cache stores recent tracks for offline replay.',
                                style: TextStyle(color: AppColors.inkSoft),
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
                      },
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

  Future<void> _openLiked() async {
    await pushAppPage(context, const LikedSongsScreen());
    _loadStats();
  }

  Widget _stat(String v, String label, {VoidCallback? onTap}) {
    final panel = GlassPanel(
      radius: 18,
      padding: const EdgeInsets.symmetric(vertical: 14),
      opacity: 0.07,
      blur: 0,
      child: Column(
        children: [
          Text(v,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.inkSoft)),
        ],
      ),
    );
    return Expanded(
      child: onTap == null
          ? panel
          : MotionPress(
              child: GestureDetector(onTap: onTap, child: panel),
            ),
    );
  }
}
