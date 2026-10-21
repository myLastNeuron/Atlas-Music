import 'package:flutter/material.dart';
import 'package:shazam_identifier/shazam_identifier.dart';

import '../models/song.dart';
import '../services/auto_listen.dart';
import '../services/identify_flow.dart';
import '../theme/app_theme.dart';
import 'artwork.dart';
import 'liquid_background.dart';
import 'play_helper.dart';
import 'song_actions.dart';

/// Two-option chooser shown from Profile: identify a song now, or turn
/// Auto listen on/off. Nothing else.
Future<void> showIdentifyMenu(BuildContext hostContext) {
  return showModalBottomSheet<void>(
    context: hostContext,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _IdentifyMenuSheet(hostContext: hostContext),
  );
}

class _IdentifyMenuSheet extends StatefulWidget {
  final BuildContext hostContext;
  const _IdentifyMenuSheet({required this.hostContext});

  @override
  State<_IdentifyMenuSheet> createState() => _IdentifyMenuSheetState();
}

class _IdentifyMenuSheetState extends State<_IdentifyMenuSheet> {
  bool _auto = AutoListenController.instance.active;

  @override
  void initState() {
    super.initState();
    AutoListenController.instance.addListener(_onAuto);
  }

  @override
  void dispose() {
    AutoListenController.instance.removeListener(_onAuto);
    super.dispose();
  }

  void _onAuto() {
    if (mounted) setState(() => _auto = AutoListenController.instance.active);
  }

  Future<void> _toggleAuto(bool value) async {
    final controller = AutoListenController.instance;
    if (value) {
      final ok = await controller.start();
      if (!mounted || ok) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not start Auto listen — allow microphone access'),
      ));
    } else {
      await controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      border: const Border(top: BorderSide(color: AppColors.line)),
      shadow: false,
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 20 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          ListTile(
            leading: const Icon(Icons.graphic_eq, color: AppColors.ink),
            title: const Text('Find song', style: TextStyle(fontSize: 15)),
            subtitle: const Text('Listen and name it now',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft)),
            onTap: () {
              Navigator.of(context).pop();
              showIdentifySheet(widget.hostContext);
            },
          ),
          ListTile(
            leading: const Icon(Icons.headphones, color: AppColors.ink),
            title: const Text('Auto listen', style: TextStyle(fontSize: 15)),
            subtitle: const Text('Name songs around you in the background',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft)),
            trailing: Switch(value: _auto, onChanged: _toggleAuto),
            onTap: () => _toggleAuto(!_auto),
          ),
        ],
      ),
    );
  }
}

/// Shazam-style flow: record ~6s of ambient audio, find the track, then let
/// the user open it (paused) in the full player or add it to a playlist.
/// Backed by the (unofficial) Shazam endpoint via `shazam_identifier` — free,
/// no API key.
///
/// [hostContext] must outlive the sheet so the follow-up actions still have a
/// valid context after it closes.
Future<void> showIdentifySheet(BuildContext hostContext) {
  return showModalBottomSheet<void>(
    context: hostContext,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _IdentifySheet(hostContext: hostContext),
  );
}

class _IdentifySheet extends StatefulWidget {
  final BuildContext hostContext;
  const _IdentifySheet({required this.hostContext});

  @override
  State<_IdentifySheet> createState() => _IdentifySheetState();
}

class _IdentifySheetState extends State<_IdentifySheet> {
  /// Bumped on every attempt and on dispose. A completing attempt whose
  /// generation is stale must not touch the UI.
  int _gen = 0;

  RecognitionStatus _status = RecognitionStatus.listening();
  bool _resolving = false;
  Song? _song;
  String? _lookupError;

  @override
  void initState() {
    super.initState();
    // After the first frame, so setState never runs inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  @override
  void dispose() {
    _gen++; // invalidate any in-flight attempt
    super.dispose();
  }

  Future<void> _listen() async {
    if (!mounted) return;
    final gen = ++_gen;

    setState(() {
      _status = RecognitionStatus.listening();
      _resolving = false;
      _song = null;
      _lookupError = null;
    });

    final status = await identifyRaw();
    if (!mounted || gen != _gen) return; // a newer attempt owns the UI
    setState(() => _status = status);

    final result = status.result;
    if (status.state != RecognitionStatusState.success || result == null) {
      return;
    }

    setState(() => _resolving = true);
    Song? song;
    String? error;
    try {
      song = await resolveSong(result);
      if (song == null) error = 'Not found on YouTube';
    } catch (_) {
      error = 'Could not search YouTube';
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _resolving = false;
      _song = song;
      _lookupError = error;
    });
  }

  void _playNow() {
    final song = _song;
    if (song == null) return;
    final host = widget.hostContext;
    Navigator.of(context).pop();
    openSongPaused(host, song);
  }

  void _addToPlaylist() {
    final song = _song;
    if (song == null) return;
    Navigator.of(context).pop();
    addSongToPlaylistFlow(widget.hostContext, song);
  }

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      border: const Border(top: BorderSide(color: AppColors.line)),
      shadow: false,
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, 20 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _body(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_song != null) return _result();
    switch (_status.state) {
      case RecognitionStatusState.ready:
      case RecognitionStatusState.listening:
      case RecognitionStatusState.processing:
        return _listening();
      case RecognitionStatusState.success:
        if (_resolving) return _loading('Finding it to play…');
        return _message(
          icon: Icons.search_off,
          title: 'Heard: ${_status.result?.title ?? 'Unknown'}',
          subtitle: _status.result?.artist ?? '',
          detail: _lookupError ?? 'Could not find it to play',
        );
      case RecognitionStatusState.noMatch:
        return _message(
          icon: Icons.music_off,
          title: 'No match found',
          subtitle: 'Try again with clearer audio',
          detail: _status.message ?? '',
        );
      case RecognitionStatusState.error:
        final msg = _status.message ?? '';
        final micDenied = msg.toLowerCase().contains('permission');
        return _message(
          icon: micDenied ? Icons.mic_off : Icons.error_outline,
          title: micDenied ? 'Microphone needed' : 'Could not find the song',
          subtitle: msg,
          detail: micDenied ? 'Allow microphone access, then try again' : '',
        );
    }
  }

  Widget _listening() {
    return Column(
      children: [
        SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const SizedBox(
                width: 96,
                height: 96,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Container(
                width: 74,
                height: 74,
                decoration: const BoxDecoration(
                  color: AppColors.mist,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.mic, size: 34, color: AppColors.ink),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text('Listening…',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const Text('Hold your phone near the music',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.inkSoft)),
        const SizedBox(height: 14),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _loading(String label) {
    return Column(
      children: [
        const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: 16),
        Text(label, style: const TextStyle(color: AppColors.inkSoft)),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _result() {
    final song = _song!;
    final result = _status.result;
    return Column(
      children: [
        Artwork(song.thumbnailUrl, size: 128, radius: 16),
        const SizedBox(height: 16),
        Text(song.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppColors.inkSoft)),
        if (result != null) ...[
          const SizedBox(height: 6),
          Text('Heard: ${result.title} — ${result.artist}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.mute)),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _playNow,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _addToPlaylist,
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add to playlist'),
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: _listen,
          child: const Text('Listen again'),
        ),
      ],
    );
  }

  Widget _message({
    required IconData icon,
    required String title,
    required String subtitle,
    required String detail,
  }) {
    return Column(
      children: [
        Icon(icon, size: 46, color: AppColors.mute),
        const SizedBox(height: 14),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.inkSoft)),
        ],
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.mute)),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _listen,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
