import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../services/storage_service.dart';
import '../services/user_prefs.dart';
import '../services/spotify_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/identify_sheet.dart';
import '../widgets/liquid_background.dart';
import '../widgets/update_sheet.dart';
import 'advanced_settings_screen.dart';
import 'auto_finds_screen.dart';
import 'liked_songs_screen.dart';

/// Settings + identity. Name edit persists and reflects in header.
class ProfileScreen extends StatefulWidget {
  final String userName;
  const ProfileScreen({super.key, required this.userName});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _prefs = UserPrefs();
  final _storage = StorageService();
  String _name = '';
  String? _avatarUrl;
  int _liked = 0;
  int _playlists = 0;
  int _recent = 0;
  bool _spotifyLinked = false;
  String? _spotifyId;
  bool _fromFdroid = false;

  @override
  void initState() {
    super.initState();
    _name = widget.userName;
    _storage.addListener(_onStorageChanged);
    _loadStats();
    _loadSpotify();
    _loadInstallerStore();
  }

  /// F-Droid re-signs the APK with its own key, so the GitHub-signed APK the
  /// updater downloads could never install over it. Hide the self-updater
  /// there; F-Droid handles updates instead.
  Future<void> _loadInstallerStore() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _fromFdroid = info.installerStore == 'org.fdroid.fdroid';
    });
  }

  void _onStorageChanged() {
    if (!mounted) return;
    _loadStats();
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    super.dispose();
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
      final old = await _prefs.getAvatar();
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await picked.saveTo(file.path);
      await _prefs.setAvatar(file.path);
      await removeOldAvatarFile(old, file.path);
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
        title: const Text('Spotify keys'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
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
    ctrl.dispose();
    if (v == null || v.isEmpty) return;
    await _prefs.setName(v);
    if (!mounted) return;
    setState(() => _name = v);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Name updated. Restart to see flight again.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = _name.isNotEmpty ? _name.trim()[0].toUpperCase() : '?';
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          // Immovable: no bounce, and the content is trimmed to fit so it does
          // not need to scroll. ponytail: assumes a tall phone viewport — trim
          // more here if it still scrolls on a short screen.
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.only(
              left: 20, right: 20, top: 14, bottom: 110),
          children: [
            const Text('Profile',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            GlassPanel(
              radius: 24,
              padding: const EdgeInsets.all(18),
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
                                        style: TextStyle(
                                            fontSize: 26,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.ink))
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
                                  child: Icon(Icons.photo_camera,
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
                            style: TextStyle(
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
            const SizedBox(height: 10),
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
            const SizedBox(height: 10),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.graphic_eq, size: 20),
                      title: const Text('Find song',
                          style: TextStyle(fontSize: 14)),
                      subtitle: Text('Find song or Auto listen',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      trailing: Icon(Icons.chevron_right,
                          color: AppColors.mute),
                      onTap: () => showIdentifyMenu(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              child: MotionPress(
                scale: 0.99,
                child: ListTile(
                  leading: const Icon(Icons.history, size: 20),
                  title: const Text('Auto song fetch history',
                      style: TextStyle(fontSize: 14)),
                  subtitle: Text('Songs Auto listen named, with times',
                      style: TextStyle(fontSize: 12, color: AppColors.inkSoft)),
                  trailing: Icon(Icons.chevron_right,
                      color: AppColors.mute),
                  onTap: () => pushAppPage(context, const AutoFindsScreen()),
                ),
              ),
            ),
            const SizedBox(height: 10),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
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
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      trailing: Icon(
                          _spotifyLinked
                              ? Icons.check_circle
                              : Icons.chevron_right,
                          color:
                              _spotifyLinked ? AppColors.ink : AppColors.mute),
                      onTap: _spotifyKeys,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            GlassPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  MotionPress(
                    scale: 0.99,
                    child: ListTile(
                      leading: const Icon(Icons.tune, size: 20),
                      title: const Text('Advanced settings',
                          style: TextStyle(fontSize: 14)),
                      subtitle: Text('Transparency, blur and surfaces',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                      trailing: Icon(Icons.chevron_right,
                          color: AppColors.mute),
                      onTap: () => pushAppPage(
                          context, const AdvancedSettingsScreen()),
                    ),
                  ),
                  // Hidden when F-Droid installed the app: its build is signed
                  // with F-Droid's key, so the GitHub-signed download the
                  // updater fetches could never install over it.
                  if (!_fromFdroid) ...[
                    Divider(height: 1, color: AppColors.line),
                    MotionPress(
                      scale: 0.99,
                      child: ListTile(
                        leading: const Icon(Icons.system_update_alt, size: 20),
                        title: const Text('Check for updates',
                            style: TextStyle(fontSize: 14)),
                        trailing: Icon(Icons.chevron_right,
                            color: AppColors.mute),
                        onTap: () => showUpdateSheet(context),
                      ),
                    ),
                  ],
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
      child: Column(
        children: [
          Text(v,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 11, color: AppColors.inkSoft)),
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
