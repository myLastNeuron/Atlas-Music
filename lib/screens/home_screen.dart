import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import 'dart:io';
import '../services/user_preferences.dart';
import '../services/user_prefs.dart' as up;
import '../services/song_filter.dart';
import '../services/quick_picks.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/play_helper.dart';
import '../widgets/skeleton_card.dart';
import 'playlist_detail_screen.dart';

const _badPhrases = [
  'lyric video',
  'lyrics',
  'karaoke',
  'made by',
  'fan made',
  'by him',
  'by me',
  'sped up',
  'speed up',
  'bass boosted',
  '1 hour',
  '10 hours',
  'movie scene',
  'dialogue',
  'full movie',
  'trailer',
  'teaser',
  'official trailer',
  'official teaser',
  'movie clip',
  'scene ',
  'preview',
  'behind the scenes',
  'billboard hot 100',
];
final _badWords = RegExp(
    r'\b(remix|remixed|remixaudio|edit|edits|slowed|reverb|short|shorts|tiktok|cover|covers|karaoke|acoustic|instrumental|upload|reupload|loop|looped|extended|8d|10d|podcast|interview|reaction)\b');

const _popularBadPhrases = [
  'viral',
  'whatsapp status',
  'reels song',
  'tiktok version',
  'speed up',
  'slowed + reverb',
  'slowed & reverb',
  'bass boosted',
  '8d audio',
  'use headphones',
  'cover song',
  'fan made',
  'unreleased',
  'billboard hot 100',
  'billboard hot',
  'trailer',
  'teaser',
  'official trailer',
  'movie',
  'clip',
];

const _badChannels = [
  'youtube movies',
  'trailer',
  'film',
  'netflix',
  'prime video',
  'hbo',
  'disney',
  'clip official',
];

const _recommendationBadPhrases = [
  'lyric video',
  'lyrics',
  'karaoke',
  'fan made',
  'fanmade',
  'sped up',
  'speed up',
  'slowed',
  'reverb',
  'bass boosted',
  'nightcore',
  'mashup',
  'bootleg',
  'unofficial',
  'reaction',
  'compilation',
  'full album',
  '1 hour',
  '10 hours',
  'movie scene',
  'dialogue',
  'full movie',
  'trailer',
  'teaser',
  'movie clip',
  'whatsapp status',
  'tiktok version',
  'reels song',
  'behind the scenes',
];
final _recommendationBadWords = RegExp(
    r'\b(remix|remixed|remixaudio|edit|edits|cover|covers|short|shorts|tiktok|instrumental|upload|reupload|loop|looped|extended|8d|10d|podcast|interview|tribute|karaoke|live performance|concert)\b');

bool _titleLongEnough(String s) => s.trim().split(RegExp(r'\s+')).length >= 2;

bool _isMusicTitle(String t) {
  // YouTube Music search returns pure song titles.
  // Keep always true to allow music-only results.
  return true;
}

List<Song> filterPopularSongs(List<Song> songs,
    {String? userName, MusicLanguage language = MusicLanguage.all}) {
  return songs.where((s) {
    final t = s.title.toLowerCase();
    final a = s.artist.toLowerCase();
    final c = s.channel.toLowerCase();
    if (!_titleLongEnough(t)) return false;
    if (s.duration.inSeconds <= 0) return false;
    // GLOBAL rules: 00:45–07:00 window + strict selected language.
    if (!SongFilter.inDurationWindow(s)) return false;
    if (SongFilter.isMusicVideo(s)) return false;
    if (!SongFilter.matchesLanguage(s, language)) return false;
    if (!_isMusicTitle(t)) return false;
    // YT Music's Songs catalogue is already a song-type filter; don't require
    // an "official" suffix that legitimate catalogue titles often omit.
    if (_badPhrases.any((b) => t.contains(b) || a.contains(b))) return false;
    if (_popularBadPhrases.any((b) => t.contains(b))) return false;
    if (_badWords.hasMatch(t) || _badWords.hasMatch(a)) return false;
    if (_badChannels.any((b) => c.contains(b))) return false;
    final uname = userName?.toLowerCase() ?? '';
    if (uname.length > 2 && (t.contains(uname) || a.contains(uname))) {
      return false;
    }
    return true;
  }).toList();
}

List<Song> filterRecommendedSongs(List<Song> songs,
    {String? userName,
    String? canonicalArtist,
    MusicLanguage language = MusicLanguage.all}) {
  Set<String> tokens(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9\u00c0-\u024f\u0900-\u097f]+'))
      .where((t) => t.length > 1)
      .toSet();

  final canon = canonicalArtist == null ? <String>{} : tokens(canonicalArtist);
  return songs.where((s) {
    final t = s.title.toLowerCase();
    final a = s.artist.toLowerCase();
    final c = s.channel.toLowerCase();
    if (t.trim().isEmpty) return false;
    // Discovery candidates must have a known, plausible song length; unlike
    // explicit user libraries, unknown-duration search hits are too risky.
    if (s.duration.inSeconds <= 0) return false;
    if (!_titleLongEnough(t) && (a.trim().isEmpty || a == 'unknown')) {
      return false;
    }
    // GLOBAL rules: 00:45–07:00 window + strict selected language.
    if (!SongFilter.inDurationWindow(s)) return false;
    if (SongFilter.isMusicVideo(s)) return false;
    if (!SongFilter.matchesLanguage(s, language)) return false;
    if (!_isMusicTitle(t)) return false;
    if (_recommendationBadPhrases.any((b) => t.contains(b) || a.contains(b))) {
      return false;
    }
    if (_popularBadPhrases.any((b) => t.contains(b))) return false;
    if (_recommendationBadWords.hasMatch(t) ||
        _recommendationBadWords.hasMatch(a)) {
      return false;
    }
    if (_badChannels.any((b) => c.contains(b))) return false;
    if (canon.isNotEmpty) {
      final titleHit = tokens(s.title).intersection(canon).isNotEmpty;
      final artistHit = tokens(s.artist).intersection(canon).isNotEmpty;
      if (!titleHit && !artistHit) return false;
      final channel = c.trim();
      if (channel.isNotEmpty) {
        final channelHit = tokens(channel).intersection(canon).isNotEmpty;
        const trustedLabelHints = [
          'vevo',
          'topic',
          'official',
          'records',
          'music',
          'entertainment',
          'sony',
          'universal',
          'warner',
          'interscope',
          'republic',
          't-series',
          'zee',
          'saregama',
          'yrf',
        ];
        final labelChannel =
            trustedLabelHints.any((hint) => channel.contains(hint));
        if (!channelHit && !labelChannel) return false;
      }
    }
    final uname = userName?.toLowerCase() ?? '';
    if (uname.length > 2 && (t.contains(uname) || a.contains(uname))) {
      return false;
    }
    return true;
  }).toList();
}

class HomeScreen extends StatefulWidget {
  final String userName;
  const HomeScreen({super.key, required this.userName});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final YouTubeService _yt = YouTubeService();
  final StorageService _storage = StorageService();
  final UserPreferences _prefs = UserPreferences();
  final up.UserPrefs _userPrefs = up.UserPrefs();

  MusicLanguage _selectedLanguage = MusicLanguage.all;
  Set<String> _selectedGenres = {};
  Set<String> _selectedArtists = {};

  List<Song> _recommended = [];
  List<Song> _recent = [];
  List<QuickPick> _quickPicks = [];
  bool _qpLoading = false;
  // No picks until first play: the first real song heard flips this
  // false and builds session-driven picks via the listener below.
  bool _qpCold = false;
  ImageProvider? _avatarProvider;
  Map<String, int> _playlistCounts = {};
  // Last song already recorded to Recently Played. The player notifies
  // listeners every second while playing — without this guard every tick
  // rewrote storage and rebuilt Home, churning the UI constantly.
  String? _lastRecentId;
  List<Playlist> _playlists = [];
  bool _recError = false;
  bool _loading = false;
  String? _avatarUrl;
  bool _hasHistory = false;

  VoidCallback? _playbackListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    up.userAvatarVersion.addListener(_onAvatarChanged);
    _loadPreferences();
    _listenToPlayback();
  }

  void _listenToPlayback() {
    _playbackListener = () {
      if (!mounted) return;
      final svc = context.read<AudioPlayerService>();
      final cur = svc.currentSong;
      // One record per song, on song change only. Position ticks fire
      // every second while playing — recording on every tick rewrote
      // storage + rebuilt this screen constantly. Pauses, background
      // preloads, and queue growth never count as new activity.
      if (cur != null && svc.isPlaying && cur.id != _lastRecentId) {
        _lastRecentId = cur.id;
        _storage.addToRecentlyPlayed(cur);
        _refreshRecent();
        // First real signal: swap cold-start generic picks for
        // session-driven ones exactly once.
        if (_qpCold && !_qpLoading) {
          _qpCold = false;
          _fetchQuickPicks(force: true);
        }
      }
    };
    context.read<AudioPlayerService>().addListener(_playbackListener!);
  }

  Future<void> _refreshRecent() async {
    final r = await _storage.getRecentlyPlayed();
    if (mounted) {
      // GLOBAL rules also cover the recent rail.
      setState(
          () => _recent = SongFilter.apply(r, language: _selectedLanguage));
    }
  }

  /// Same shared avatar as Profile: standalone read with its own guard,
  /// so a corrupt unrelated pref can never blank the photo on one
  /// screen while the other still shows it.
  bool _avatarError = false;
  Future<void> _refreshAvatar() async {
    try {
      final avatar = await _userPrefs.getAvatar();
      if (!mounted) return;
      if (avatar != _avatarUrl) {
        ImageProvider? provider;
        if (avatar != null && !_avatarError) {
          try {
            provider = (avatar.startsWith('http')
                ? NetworkImage(avatar)
                : FileImage(File(avatar))) as ImageProvider;
          } catch (_) {
            provider = null;
          }
        }
        setState(() {
          _avatarUrl = avatar;
          _avatarError = false;
          _avatarProvider = provider;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadPreferences() async {
    // Avatar first and independent: must match Profile even if another
    // pref read below throws.
    await _refreshAvatar();
    final language = await _prefs.getLanguage();
    final genres = await _prefs.getGenres();
    final artists = await _prefs.getArtists();
    if (!mounted) return;
    setState(() {
      _selectedLanguage = language;
      _selectedGenres = genres;
      _selectedArtists = artists;
    });
    await _load();
  }

  Future<void> _load({bool force = false}) async {
    if (_loading && !force) return;
    _loading = true;
    try {
      final recent = await _storage.getRecentlyPlayed();
      final pls = await _storage.getPlaylists();
      final hasHistory = await _storage.hasEnoughHistory();
      if (!mounted) return;
      final counts = <String, int>{};
      for (final p in pls) {
        // Playlists report every song they contain (no language/duration
        // filtering); discovery surfaces still filter.
        counts[p.id] = p.songs.length;
      }
      setState(() {
        _recent = SongFilter.apply(recent, language: _selectedLanguage);
        _playlists = pls;
        _playlistCounts = counts;
        _hasHistory = hasHistory;
      });

      if (!hasHistory) {
        setState(() {
          _recommended = [];
          _recError = false;
        });
        await _fetchQuickPicks();
        return;
      }

      // Build queries only from actual user taste; never fall back to a
      // global celebrity/trending list when personal signals are missing.
      final queries = <String>[];
      void addQuery(String value) {
        final query = value.trim();
        if (query.isEmpty) return;
        final key = query.toLowerCase();
        if (!queries.any((existing) => existing.toLowerCase() == key)) {
          queries.add(query);
        }
      }

      final langName = _selectedLanguage != MusicLanguage.all
          ? _selectedLanguage.name.toLowerCase()
          : '';
      final topArtists = await _storage.getTopArtists(limit: 8);
      final topGenres = await _storage.getTopGenres(limit: 5);
      final liked = await _storage.getLikedSongs();
      final searchHistory = await _storage.getSearchHistory();

      for (final artist in _selectedArtists) {
        addQuery('$artist songs');
      }
      for (final artist in topArtists.take(5)) {
        addQuery('$artist songs');
      }
      for (final song in recent.take(6)) {
        if (song.artist.trim().isNotEmpty &&
            song.artist.toLowerCase() != 'unknown') {
          addQuery('${song.artist} songs');
        }
      }
      for (final song in liked.take(4)) {
        if (song.artist.trim().isNotEmpty &&
            song.artist.toLowerCase() != 'unknown') {
          addQuery('${song.artist} songs');
        }
      }
      for (final genre in [..._selectedGenres, ...topGenres].take(5)) {
        addQuery('$genre ${langName.isEmpty ? '' : '$langName '}songs');
      }
      for (final query in searchHistory.take(3)) {
        addQuery(query);
      }

      final tasteArtists = <String>{
        ..._selectedArtists,
        ...topArtists,
        ...recent.map((song) => song.artist),
        ...liked.map((song) => song.artist),
      }..removeWhere((artist) =>
          artist.trim().isEmpty || artist.toLowerCase() == 'unknown');
      String? canonicalArtistFor(String query) {
        final key = query.trim().toLowerCase();
        for (final artist in tasteArtists) {
          if (key == '${artist.toLowerCase()} songs') return artist;
        }
        return null;
      }

      // Quick picks remain their own personalized rail. Recommendation
      // results are gathered first and ranked as one pool, not appended in
      // whichever network request happens to finish first.
      final picksFuture = _fetchQuickPicks();
      final resultGroups = await Future.wait(
        queries.take(6).map((query) => _fetchRecommended(
              query,
              canonicalArtist: canonicalArtistFor(query),
            )),
      );
      await picksFuture;
      if (!mounted) return;
      final candidates = resultGroups.expand((group) => group).toList();
      final stats = await _storage.getListeningStats();
      if (!mounted) return;
      final audio = context.read<AudioPlayerService>();
      final queueIds = audio.queue
          .expand((song) => [song.id, song.videoId ?? song.id])
          .followedBy(_quickPicks.expand(
              (pick) => [pick.song.id, pick.song.videoId ?? pick.song.id]))
          .toSet();
      final ranked = QuickPicksEngine.rank(
        recent: recent.take(5).toList(),
        candidates: candidates,
        stats: stats,
        topArtists: topArtists,
        topGenres: [...topGenres, ..._selectedGenres],
        likedIds: liked.map((song) => song.id).toSet(),
        queueIds: queueIds,
        userLanguage: _selectedLanguage,
        searchHistory: searchHistory,
        selectedArtists: _selectedArtists.toList(),
        count: 25,
        includeStretchPick: false,
        requirePersonalSignal: true,
      );
      if (!mounted) return;
      setState(() {
        _recommended = ranked.map((pick) => pick.song).toList();
        _recError = candidates.isEmpty;
      });
    } finally {
      _loading = false;
    }
  }

  /// Session-aware Quick Picks: the seed (current or latest track) drives
  /// candidate queries, then [QuickPicksEngine] ranks them. Generated
  /// ONCE per app launch and on manual refresh only — never rolling.
  /// Playing, skipping, pausing, browsing, or background queue growth
  /// must not replace the visible rail.
  Future<void> _fetchQuickPicks({bool force = false}) async {
    if (_qpLoading) return;
    // Stable rail: keep showing the current picks unless the user asked
    // for fresh ones (pull-to-refresh / refresh button) or there are none
    // yet (cold start).
    if (!force && _quickPicks.isNotEmpty) return;
    _qpLoading = true;
    try {
      final audio = context.read<AudioPlayerService>();
      final seed = audio.currentSong;
      final rawRecent = await _storage.getRecentlyPlayed();
      final recent = SongFilter.apply(rawRecent, language: _selectedLanguage);
      final effectiveSeed = seed ?? (recent.isNotEmpty ? recent.first : null);
      final stats = await _storage.getListeningStats();
      final topArtists = await _storage.getTopArtists(limit: 10);
      final topGenres = await _storage.getTopGenres(limit: 5);
      final liked = await _storage.getLikedSongs();
      final searches = await _storage.getSearchHistory();
      final queueIds = audio.queue
          .map((s) => s.videoId ?? s.id)
          .followedBy(audio.queue.map((s) => s.id))
          .toSet();

      // No listening yet: no picks at all. Quick Picks only suggest
      // after the user heard a song — never generic placeholders.
      if (effectiveSeed == null && recent.isEmpty) {
        if (!mounted) return;
        setState(() {
          _quickPicks = [];
          _qpCold = true;
        });
        return;
      }

      final lang = _selectedLanguage;
      // Diverse queries: every taste source gets its own query so the pool
      // spans artists. Single-artist pools collapse below 10 after the
      // engine's per-artist cap. Session artists lead for similarity.
      final queries = <String>[];
      void addQuery(String q) {
        final query = q.trim();
        if (query.isEmpty) return;
        final key = query.toLowerCase();
        if (!queries.any((e) => e.toLowerCase() == key)) queries.add(query);
      }

      if (effectiveSeed != null && effectiveSeed.artist.isNotEmpty) {
        addQuery('${effectiveSeed.artist} songs');
      }
      for (final artist in topArtists.take(4)) {
        if (effectiveSeed != null &&
            artist.toLowerCase() == effectiveSeed.artist.toLowerCase()) {
          continue;
        }
        addQuery('$artist songs');
      }
      for (final artist in _selectedArtists.take(3)) {
        addQuery('$artist songs');
      }
      for (final song in liked.take(4)) {
        if (song.artist.trim().isNotEmpty &&
            song.artist.toLowerCase() != 'unknown') {
          addQuery('${song.artist} songs');
        }
      }
      for (final song in recent.skip(1).take(4)) {
        if (song.artist.trim().isNotEmpty &&
            song.artist.toLowerCase() != 'unknown') {
          addQuery('${song.artist} songs');
        }
      }
      for (final genre in [..._selectedGenres, ...topGenres].take(3)) {
        addQuery('$genre songs');
      }
      for (final query in searches.take(2)) {
        addQuery(query);
      }

      final tasteArtists = <String>{
        ..._selectedArtists,
        ...topArtists,
        ...recent.map((song) => song.artist),
        ...liked.map((song) => song.artist),
      }..removeWhere((artist) =>
          artist.trim().isEmpty || artist.toLowerCase() == 'unknown');
      String? canonicalArtistFor(String query) {
        final key = query.trim().toLowerCase();
        for (final artist in tasteArtists) {
          if (key == '${artist.toLowerCase()} songs') return artist;
        }
        return null;
      }

      final pool = <Song>[];
      final seen = <String>{};
      Future<void> fetchQuery(String q,
          {int limit = 12, String? canonicalArtist}) async {
        try {
          final songs = await _yt
              .search(q, limit: limit)
              .timeout(const Duration(seconds: 8));
          final qualified = filterRecommendedSongs(
            songs,
            userName: widget.userName,
            canonicalArtist: canonicalArtist,
            language: lang,
          );
          for (final s in qualified) {
            final vid = s.videoId ?? s.id;
            if (seen.add(vid)) pool.add(s);
          }
        } catch (_) {}
      }

      await Future.wait(queries.take(6).map((q) =>
          fetchQuery(q, limit: 16, canonicalArtist: canonicalArtistFor(q))));
      if (!mounted) return;
      final sessionRecent = effectiveSeed != null
          ? [
              effectiveSeed,
              ...recent.where((s) => s.id != effectiveSeed.id).take(4)
            ]
          : recent.take(5).toList();
      final picks = QuickPicksEngine.rank(
        recent: sessionRecent,
        candidates: pool,
        stats: stats,
        topArtists: topArtists,
        topGenres: [...topGenres, ..._selectedGenres],
        likedIds: liked.map((s) => s.id).toSet(),
        queueIds: queueIds,
        userLanguage: lang,
        collaborative: const {},
        searchHistory: searches,
        selectedArtists: _selectedArtists.toList(),
        count: 10,
        seedHint: (effectiveSeed?.id ?? '').hashCode,
        includeStretchPick: false,
        requirePersonalSignal: true,
      );
      if (!mounted) return;
      setState(() {
        _quickPicks = picks;
        // No session signal went in: placeholders until first play.
        _qpCold = sessionRecent.isEmpty;
      });
    } finally {
      _qpLoading = false;
    }
  }

  /// Manual Quick Picks refresh: clear the stable rail and generate a
  /// fresh set. This + pull-to-refresh + cold start are the ONLY paths
  /// that replace the visible picks.
  Future<void> _refreshQuickPicks() async {
    setState(() => _quickPicks = []);
    await _fetchQuickPicks(force: true);
  }

  Future<List<Song>> _fetchRecommended(
    String query, {
    String? canonicalArtist,
  }) async {
    try {
      final songs = await _yt
          .search(query, limit: 15)
          .timeout(const Duration(seconds: 8));
      if (songs.isEmpty) return const [];
      return filterRecommendedSongs(songs,
          userName: widget.userName,
          canonicalArtist: canonicalArtist,
          language: _selectedLanguage);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _play(Song song, List<Song> queue, int index,
      {String? queueOrigin}) async {
    final safeIndex =
        queue.indexWhere((s) => s.videoId == song.videoId || s.id == song.id);
    final idx = safeIndex >= 0 ? safeIndex : index;
    await playSongs(context,
        song: song, queue: queue, index: idx, queueOrigin: queueOrigin);
    _storage.addToRecentlyPlayed(song);
    _refreshRecent();
  }

  /// "Play Quick Picks": play every currently displayed pick in order,
  /// starting immediately. The queue is tagged so that when the picks
  /// finish, personalized continuations keep playing automatically.
  Future<void> _playQuickPicks() async {
    final songs = _quickPicks.map((e) => e.song).toList();
    if (songs.isEmpty) return;
    await _play(songs.first, songs, 0, queueOrigin: 'quickPicks');
  }

  Future<void> _createPlaylistDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('New playlist'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              hintText: 'Playlist name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await _storage.savePlaylist(Playlist(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        songs: const [],
        createdAt: DateTime.now(),
        source: 'local',
      ));
      if (!mounted) return;
      final p = await _storage.getPlaylists();
      if (!mounted) return;
      final counts = <String, int>{};
      for (final pl in p) {
        counts[pl.id] = pl.songs.length;
      }
      setState(() {
        _playlists = p;
        _playlistCounts = counts;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playlist "$name" created')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create playlist')),
      );
    }
  }

  Widget _createPlaylistBanner() {
    return MotionPress(
      child: GestureDetector(
        onTap: _createPlaylistDialog,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.mist,
                    ),
                    child: const Icon(Icons.album,
                        size: 84, color: AppColors.mute),
                  ),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: const Icon(Icons.add,
                        size: 28, color: AppColors.charcoal),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CREATE NEW\nPLAYLIST',
                        style: TextStyle(
                            color: AppColors.ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            height: 1.1)),
                    SizedBox(height: 8),
                    Text('Build your dream mix',
                        style:
                            TextStyle(color: AppColors.inkSoft, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playlistsSection() {
    if (_playlists.isEmpty) {
      return MotionPress(
        child: GestureDetector(
          onTap: _createPlaylistDialog,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppColors.glassBorder, style: BorderStyle.solid),
              color: Colors.white.withValues(alpha: 0.04),
            ),
            child: const Column(
              children: [
                Icon(Icons.queue_music, size: 32, color: AppColors.mute),
                SizedBox(height: 8),
                Text('No playlists yet',
                    style: TextStyle(
                        color: AppColors.inkSoft, fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text('Tap to build your first mix',
                    style: TextStyle(color: AppColors.mute, fontSize: 12)),
              ],
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollCacheExtent: const ScrollCacheExtent.pixels(600), scrollDirection: Axis.horizontal,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemCount: _playlists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = _playlists[i];
          final art = p.thumbnailUrl ?? '';
          return MotionPress(
            child: GestureDetector(
              onTap: () async {
                await pushAppPage(
                  context,
                  PlaylistDetailScreen(playlist: p),
                );
                // Refresh playlists after returning (song may have been
                // added/removed).
                final updated = await _storage.getPlaylists();
                if (mounted) {
                  final counts = <String, int>{};
                  for (final p in updated) {
                    counts[p.id] = p.songs.length;
                  }
                  setState(() {
                    _playlists = updated;
                    _playlistCounts = counts;
                  });
                }
              },
              child: Container(
                width: 220,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Row(
                  children: [
                    art.isEmpty
                        ? Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: AppColors.mist,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.queue_music,
                                color: AppColors.mute),
                          )
                        : Artwork(art, size: 64, radius: 12),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.ink,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(
                              '${_playlistCounts[p.id] ?? p.songs.length} songs',
                              style: const TextStyle(
                                  color: AppColors.inkSoft, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _recentlyPlayedSection() {
    if (_recent.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: AppColors.glassBorder, style: BorderStyle.solid),
          color: Colors.white.withValues(alpha: 0.04),
        ),
        child: const Column(
          children: [
            Icon(Icons.history, size: 32, color: AppColors.mute),
            SizedBox(height: 8),
            Text('No recently played songs',
                style: TextStyle(
                    color: AppColors.inkSoft, fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text('Songs you play will appear here',
                style: TextStyle(color: AppColors.mute, fontSize: 12)),
          ],
        ),
      );
    }
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollCacheExtent: const ScrollCacheExtent.pixels(600), scrollDirection: Axis.horizontal,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemCount: _recent.length,
        itemBuilder: (context, i) {
          final s = _recent[i];
          return MotionPress(
            child: GestureDetector(
              onTap: () => _play(s, _recent, i),
              child: Container(
                width: 150,
                margin: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        children: [
                          Artwork(s.thumbnailUrl,
                              width: 150, height: 130, radius: 0),
                          Positioned(
                            bottom: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: AppColors.ultraviolet.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(Icons.play_arrow,
                                  size: 18, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    Text(s.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.inkSoft, fontSize: 11)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _recommendedList() {
    if (_loading && _recommended.isEmpty) {
      return SizedBox(
        height: 300,
        child: ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 15,
          itemBuilder: (_, __) => const SkeletonListItem(),
        ),
      );
    }
    if (_recommended.isEmpty) {
      if (!_hasHistory) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text('Listen to some music and we\'ll find your best picks.',
                style: TextStyle(color: AppColors.inkSoft, fontSize: 13)),
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('No unique recommendations — check back soon',
              style: TextStyle(color: AppColors.mute, fontSize: 12)),
        ),
      );
    }
    final items = _recommended;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length > 25 ? 25 : items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final s = items[i];
        return MotionPress(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Artwork(s.thumbnailUrl, size: 48, radius: 10),
            title: Text(s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            subtitle: Text(s.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.inkSoft, fontSize: 11)),
            trailing: Text(_fmtDur(s.duration),
                style: const TextStyle(color: AppColors.inkSoft, fontSize: 12)),
            onTap: () => _play(s, items, i),
          ),
        );
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Warm resume is NOT a reopen: refresh the recent rail + avatar only.
    // A full reload would regenerate Quick Picks every time the user
    // returns from background or the player screen.
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshRecent();
      _refreshAvatar();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    up.userAvatarVersion.removeListener(_onAvatarChanged);
    if (_playbackListener != null) {
      context.read<AudioPlayerService>().removeListener(_playbackListener!);
    }
    _yt.dispose();
    super.dispose();
  }

  void _onAvatarChanged() {
    _refreshAvatar();
  }

  Future<void> _onRefresh() async {
    _recommended = [];
    _quickPicks = [];
    _lastRecentId = null;
    _recent = [];
    _playlists = [];
    _recError = false;
    if (mounted) setState(() {});
    await _load(force: true);
  }

  @override
  Widget build(BuildContext context) {
    // Stable rail: NO seed check here. The picks generated at cold start
    // (or manual refresh) stay put while playing, skipping, pausing, or
    // browsing. Background continuation + preloading never touch them.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _onRefresh,
          backgroundColor: AppColors.card,
          color: AppColors.ultraviolet,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics()),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.mist,
                        backgroundImage:
                            (_avatarError || _avatarProvider == null)
                                ? null
                                : _avatarProvider,
                        onBackgroundImageError: (_, __) {
                          // Dead file / offline URL: fall back to the icon
                          // instead of a blank circle that would mismatch
                          // the other header.
                          if (mounted && !_avatarError) {
                            setState(() {
                              _avatarError = true;
                              _avatarProvider = null;
                            });
                          }
                        },
                        child: (_avatarUrl == null || _avatarError)
                            ? const Icon(Icons.person,
                                size: 20, color: AppColors.inkSoft)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.userName,
                              style: const TextStyle(
                                  color: AppColors.ink,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_recent.isNotEmpty) ...[
                    Row(
                      children: [
                        const Text('Recently Played',
                            style: TextStyle(
                                color: AppColors.ink,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.glassBorder),
                          ),
                          child: Text(
                            '${_recent.length} songs',
                            style: const TextStyle(
                                color: AppColors.inkSoft, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _recentlyPlayedSection(),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.glassBorder),
                        ),
                        child: const Icon(Icons.bolt,
                            size: 16, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Quick Picks',
                                style: TextStyle(
                                    color: AppColors.ink,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                            Text('Tuned to your session',
                                style: TextStyle(
                                    color: AppColors.inkSoft, fontSize: 11)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh Quick Picks',
                        onPressed: _refreshQuickPicks,
                        icon: const Icon(Icons.refresh,
                            size: 20, color: AppColors.inkSoft),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _quickPicks.isEmpty ? null : _playQuickPicks,
                      icon: const Icon(Icons.play_arrow, size: 20),
                      label: const Text('Play Quick Picks',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.charcoal,
                        disabledBackgroundColor:
                            Colors.white.withValues(alpha: 0.25),
                        disabledForegroundColor:
                            AppColors.inkSoft.withValues(alpha: 0.6),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 200,
                    child: _loading && _quickPicks.isEmpty
                        ? ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: 10,
                            itemBuilder: (_, __) => const SkeletonCard(),
                          )
                        : _quickPicks.isEmpty
                            ? Center(
                                child: _recError
                                    ? TextButton.icon(
                                        onPressed: () {
                                          setState(() => _recError = false);
                                          _load();
                                        },
                                        icon: const Icon(Icons.refresh,
                                            color: AppColors.inkSoft),
                                        label: const Text(
                                            'Couldn\'t load songs — tap to retry',
                                            style: TextStyle(
                                                color: AppColors.inkSoft,
                                                fontSize: 13)),
                                      )
                                    : const Text(
                                        'Play a song to get picks tuned to your session',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color: AppColors.mute,
                                            fontSize: 13)),
                              )
                            : Builder(builder: (context) {
                                final songs =
                                    _quickPicks.map((e) => e.song).toList();
                                return ListView.builder(
                                  scrollCacheExtent: const ScrollCacheExtent.pixels(600), scrollDirection: Axis.horizontal,
                                  addAutomaticKeepAlives: false,
                                  addRepaintBoundaries: true,
                                  itemCount: _quickPicks.length,
                                  itemBuilder: (context, i) {
                                    final pick = _quickPicks[i];
                                    final s = pick.song;
                                    return MotionPress(
                                      child: GestureDetector(
                                        onTap: () => _play(s, songs, i,
                                            queueOrigin: 'quickPicks'),
                                        child: Container(
                                          width: 150,
                                          margin:
                                              const EdgeInsets.only(right: 12),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                child: Stack(
                                                  children: [
                                                    Artwork(s.thumbnailUrl,
                                                        width: 150,
                                                        height: 112,
                                                        radius: 0),
                                                    Positioned(
                                                      bottom: 6,
                                                      right: 6,
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .all(6),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: Colors.white,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(20),
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: Colors
                                                                  .black
                                                                  .withValues(
                                                                      alpha:
                                                                          0.35),
                                                              blurRadius: 10,
                                                              offset:
                                                                  const Offset(
                                                                      0, 3),
                                                            ),
                                                          ],
                                                        ),
                                                        child: const Icon(
                                                            Icons.play_arrow,
                                                            size: 18,
                                                            color: AppColors
                                                                .charcoal),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(s.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      color: AppColors.ink,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500)),
                                              Text(s.artist,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      color: AppColors.inkSoft,
                                                      fontSize: 11)),
                                              Text(pick.reason,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      color: AppColors.mute,
                                                      fontSize: 10)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              }),
                  ),
                  const SizedBox(height: 20),
                  _createPlaylistBanner(),
                  const SizedBox(height: 20),
                  const Text('YOUR PLAYLISTS',
                      style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  _playlistsSection(),
                  const SizedBox(height: 20),
                  const Text('RECOMMENDED FOR YOU',
                      style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  _recommendedList(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
