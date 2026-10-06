import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/song_filter.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/liquid_background.dart';
import '../widgets/artwork.dart';
import '../widgets/app_transitions.dart';
import '../widgets/play_helper.dart';
import '../widgets/song_actions.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final YouTubeService _yt = YouTubeService();
  final StorageService _storage = StorageService();
  List<Song> _results = [];
  bool _loading = false;
  bool _searched = false;
  List<String> _history = [];
  // Overlapping searches: only the latest request may publish results,
  // so a slow earlier request finishing last cannot overwrite fresh
  // results or raise a stale failure toast for a replaced query.
  int _searchGen = 0;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final h = await _storage.getSearchHistory();
    if (mounted) setState(() => _history = h);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _yt.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    final int gen = ++_searchGen;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    await _storage.addSearchQuery(q.trim());
    await _loadHistory();
    if (!mounted || gen != _searchGen) return;
    try {
      final r = await _yt.searchAll(q.trim(), limit: 25);
      if (!mounted || gen != _searchGen) return;
      setState(() {
        // Search: explicit request — keep every music upload (slowed/reverb,
        // remix, lyric, sped-up, official video) while stripping non-music
        // (trailers, movies, TV, podcasts, long-form).
        final filtered = SongFilter.applySearch(r);
        _results = filtered.where((s) => s.videoId != null).toList();
        _loading = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() => _loading = false);
      // Report the actual failure instead of always blaming the
      // connection: timeouts, provider throttling, and server errors are
      // not connection problems. Detail is truncated for the snackbar.
      final raw = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      final short = raw.length > 160 ? '${raw.substring(0, 160)}…' : raw;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search failed: $short')),
      );
    }
  }

  Future<void> _play(Song s) async {
    // Search plays ONLY the tapped song, then seed-based radio keeps
    // playing tracks similar to it (see _playSeedRadio). The result
    // list is not a queue: finishing never walks down the list.
    await playSongs(context,
        song: s,
        queue: [s],
        index: 0,
        autoplayOnEnd: true,
        queueOrigin: 'search');
    try {
      await _storage.addToRecentlyPlayed(s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final hasSong =
        context.select<AudioPlayerService, bool>((s) => s.currentSong != null);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 20, right: 20, top: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Search',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 22),
                    tooltip: 'Clear search history',
                    onPressed: () async {
                      await _storage.clearSearchHistory();
                      await _loadHistory();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: GlassPanel(
                radius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                opacity: 0.09,
                child: TextField(
                  controller: _ctrl,
                  decoration: InputDecoration(
                    hintText: 'Search songs, artists...',
                    hintStyle: const TextStyle(color: AppColors.mute),
                    prefixIcon: const Icon(Icons.search, color: AppColors.mute),
                    suffixIcon: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _ctrl,
                      builder: (_, value, __) {
                        if (value.text.isEmpty) return const SizedBox.shrink();
                        return IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _ctrl.clear();
                            setState(() {
                              _results = [];
                              _searched = false;
                            });
                          },
                        );
                      },
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onSubmitted: _search,
                  textInputAction: TextInputAction.search,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppMotion.dur(context, AppMotion.micro),
                switchInCurve: AppMotion.curve,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: fadeRiseTransition,
                child: _loading
                    ? const Center(
                        key: ValueKey('search-loading'),
                        child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : _results.isEmpty
                        ? _searched
                            ? const Center(
                                key: ValueKey('search-empty'),
                                child: Text(
                                  'No results found',
                                  style: TextStyle(color: AppColors.inkSoft),
                                ),
                              )
                            : _history.isEmpty
                                ? const Center(
                                    key: ValueKey('search-idle'),
                                    child: Text(
                                      'Search for your favorite music',
                                      style:
                                          TextStyle(color: AppColors.inkSoft),
                                    ),
                                  )
                                : ListView.builder(
                                    key: const ValueKey('search-history'),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 12),
                                    itemCount: _history.length + 1,
                                    itemBuilder: (_, i) {
                                      if (i == 0) {
                                        return const Padding(
                                          padding: EdgeInsets.only(bottom: 8),
                                          child: Text('Recent searches',
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  color: AppColors.inkSoft)),
                                        );
                                      }
                                      final q = _history[i - 1];
                                      return MotionPress(
                                        child: ListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          leading: const Icon(Icons.history,
                                              size: 18,
                                              color: AppColors.inkSoft),
                                          title: Text(q,
                                              style: const TextStyle(
                                                  fontSize: 14)),
                                          trailing: IconButton(
                                            icon: const Icon(Icons.close,
                                                size: 18),
                                            onPressed: () async {
                                              final updated =
                                                  List<String>.from(_history);
                                              updated.removeAt(i - 1);
                                              await _storage
                                                  .clearSearchHistory();
                                              for (final item in updated) {
                                                await _storage
                                                    .addSearchQuery(item);
                                              }
                                              await _loadHistory();
                                            },
                                          ),
                                          onTap: () {
                                            _ctrl.text = q;
                                            _search(q);
                                          },
                                        ),
                                      );
                                    },
                                  )
                        : ListView.separated(
                            scrollCacheExtent:
                                const ScrollCacheExtent.pixels(600),
                            key: const ValueKey('search-results'),
                            padding: EdgeInsets.only(
                                left: 12,
                                right: 12,
                                bottom: hasSong ? 190 : 120),
                            physics: const BouncingScrollPhysics(),
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 2),
                            itemBuilder: (_, i) {
                              final s = _results[i];
                              return MotionPress(
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                  leading: Artwork(
                                    s.thumbnailUrl,
                                    size: 48,
                                    radius: 10,
                                  ),
                                  title: Text(s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500)),
                                  subtitle: Text(s.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: AppColors.inkSoft,
                                          fontSize: 12)),
                                  trailing: SongMenuButton(
                                    song: s,
                                    queue: [s],
                                    index: 0,
                                    queueOrigin: 'search',
                                  ),
                                  onTap: () => _play(s),
                                ),
                              );
                            },
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
