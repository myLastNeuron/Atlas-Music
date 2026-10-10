import 'package:flutter/material.dart';
import '../media/lyrics_model.dart';
import '../theme/app_theme.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/lyrics_service.dart';
import 'app_transitions.dart';

/// Bottom-sheet synced lyrics. Listens to ExoPlayer positionStream
/// directly (smooth tick), highlights current line, auto-scrolls
/// with ensureVisible, tap any line to seek. Plain fallback when
/// no timestamps exist; honest empty states otherwise.
class LyricsSheet extends StatefulWidget {
  final Song song;
  final AudioPlayerService audio;

  const LyricsSheet({
    super.key,
    required this.song,
    required this.audio,
  });

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  late final Future<SyncedLyrics?> _future;
  late final LyricsService _service;
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};
  int _current = -1;
  List<String>? _translated;
  bool _showTranslated = false;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    _service = LyricsService();
    _future = _service.fetch(widget.song);
  }

  @override
  void dispose() {
    _service.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _toggleTranslation(List<String> lines, String target) async {
    if (_showTranslated) {
      setState(() => _showTranslated = false);
      return;
    }
    if (_translated != null) {
      setState(() => _showTranslated = true);
      return;
    }
    setState(() => _translating = true);
    final result = await _service.translate(lines, target);
    if (!mounted) return;
    setState(() {
      _translated = result;
      _showTranslated = result != null;
      _translating = false;
    });
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Translation unavailable')));
    }
  }

  void _maybeScroll(int next) {
    if (next == _current) return;
    _current = next;
    final key = _keys[next];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.4,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        );
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: const BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Lyrics',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('${song.title} • ${song.artist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                    ],
                  ),
                ),
                FutureBuilder<SyncedLyrics?>(
                  future: _future,
                  builder: (context, snap) {
                    final d = snap.data;
                    if (d == null || d.instrumental) {
                      return const SizedBox.shrink();
                    }
                    final lines = d.isSynced
                        ? d.lines.map((l) => l.text).toList()
                        : (d.plain ?? '').split('\n');
                    if (lines.every((l) => l.trim().isEmpty)) {
                      return const SizedBox.shrink();
                    }
                    final target = Localizations.localeOf(context).languageCode;
                    return TextButton.icon(
                      icon: _translating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.translate, size: 18),
                      label: Text(_showTranslated ? 'Original only' : 'Translate'),
                      onPressed: _translating
                          ? null
                          : () => _toggleTranslation(lines, target),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 22),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: FutureBuilder<SyncedLyrics?>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final data = snap.data;
                if (data == null) {
                  return _empty(
                    icon: Icons.lyrics_outlined,
                    title: 'No lyrics found',
                    sub: 'LRCLIB has nothing for this track yet.',
                  );
                }
                if (data.instrumental) {
                  return _empty(
                    icon: Icons.music_note,
                    title: 'Instrumental',
                    sub: 'No lyrics for this track.',
                  );
                }
                if (!data.isSynced) {
                  final plain = data.plain ?? '';
                  if (plain.trim().isEmpty) {
                    return _empty(
                      icon: Icons.lyrics_outlined,
                      title: 'No synced lyrics',
                      sub: 'Only unsynced text exists.',
                    );
                  }
                  final src = plain.split('\n');
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < src.length; i++) ...[
                          Text(
                            src[i],
                            style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.5,
                                color: AppColors.mute),
                          ),
                          if (_showTranslated &&
                              _translated != null &&
                              i < _translated!.length)
                            Text(
                              _translated![i],
                              style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.5,
                                  color: AppColors.inkSoft),
                            ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  );
                }
                for (var i = 0; i < data.lines.length; i++) {
                  _keys.putIfAbsent(i, () => GlobalKey());
                }
                return StreamBuilder<Duration>(
                  stream: widget.audio.player.positionStream,
                  initialData: widget.audio.position,
                  builder: (context, posSnap) {
                    final pos = posSnap.data ?? Duration.zero;
                    final idx = data.indexFor(pos);
                    _maybeScroll(idx);
                    return ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                      itemCount: data.lines.length,
                      itemBuilder: (context, i) {
                        final line = data.lines[i];
                        final active = i == idx;
                        return MotionPress(
                          child: GestureDetector(
                            key: _keys[i],
                            onTap: () => widget.audio.seek(line.start),
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    line.text,
                                    style: TextStyle(
                                      fontSize: active ? 13.5 : 12.5,
                                      height: 1.4,
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: active
                                          ? AppColors.inkSoft
                                          : AppColors.mute,
                                    ),
                                  ),
                                  if (_showTranslated &&
                                      _translated != null) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      _translated![i],
                                      style: TextStyle(
                                        fontSize: active ? 18 : 16,
                                        height: 1.4,
                                        fontWeight: active
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: active
                                            ? AppColors.ink
                                            : AppColors.inkSoft,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(
      {required IconData icon, required String title, required String sub}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppColors.mute),
            const SizedBox(height: 12),
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(sub,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.inkSoft)),
          ],
        ),
      ),
    );
  }
}
