import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/play_helper.dart';
import '../widgets/song_actions.dart';

/// Full listening history, newest first. Raw user data — no discovery
/// filters. Each row can be deleted; the top bin wipes everything locally.
/// Long-press enters multi-select, which reveals a delete/cancel bar.
/// Listens to storage so deletes and new plays reflect instantly.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _storage = StorageService.instance;
  List<Song> _history = [];
  bool _loading = true;

  // Multi-select: indices point into the frozen _history snapshot so a
  // background reload cannot shift the row a tap targets.
  final MultiSelectController _sel = MultiSelectController();
  bool get _selecting => _sel.selecting;
  Set<int> get _selected => _sel.selected;

  @override
  void initState() {
    super.initState();
    _storage.addListener(_onStorageChanged);
    _load();
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onStorageChanged() {
    // Freeze reloads while selecting: a background play must not shift row
    // indices out from under the current selection.
    if (_selecting) return;
    _load();
  }

  Future<void> _load() async {
    final r = await _storage.getRecentlyPlayed();
    if (!mounted) return;
    setState(() {
      _history = r;
      _loading = false;
    });
  }

  Future<void> _remove(Song song) async {
    // Remove ONE occurrence, not every copy. Batch delete still offers the
    // all-copies choice.
    await _storage.removeRecentEntries([song], allCopies: false);
    // Listener reloads; no manual refresh needed.
  }

  void _startSelection(int i) => setState(() => _sel.start(i));

  void _toggle(int i) => setState(() => _sel.toggle(i));

  void _exitSelection() {
    if (!_sel.selecting && _sel.selected.isEmpty) return;
    setState(_sel.exit);
    _load();
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final selected = _selected.map((i) => _history[i]).toList();

    // Does any selected song have copies that are NOT selected? Only then
    // is there a real choice between "all copies" and "only these".
    final selectedCounts = <String, int>{};
    for (final s in selected) {
      selectedCounts[s.id] = (selectedCounts[s.id] ?? 0) + 1;
    }
    final hasHiddenCopies = selectedCounts.entries
        .any((e) => _history.where((s) => s.id == e.key).length > e.value);

    bool allCopies = true;
    if (hasHiddenCopies) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.glass,
          title: const Text('Delete history'),
          content: const Text(
            'Some of these songs appear more than once. Delete every copy, '
            'or only the ones you selected?',
            style: TextStyle(color: AppColors.inkSoft),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Only selected'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('All copies', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (choice == null) return;
      allCopies = choice;
    }

    await _storage.removeRecentEntries(selected, allCopies: allCopies);
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.glass,
        title: const Text('Delete all history?'),
        content: const Text(
          'The action you are gonna do can be severe and it would delete '
          'all song history locally and you won\'t be able to retrieve '
          'them again.',
          style: TextStyle(color: AppColors.inkSoft),
        ),
        actions: [
          // Preselected: Enter/OK cancels unless the user deliberately
          // picks Continue. Keeps the destructive path opt-in.
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _storage.clearRecentlyPlayed();
  }

  Widget _selectionBar() {
    return SelectionBar(
      count: _selected.length,
      onCancel: _exitSelection,
      actions: [
        TextButton(
          onPressed: _selected.isEmpty ? null : _deleteSelected,
          child: const Text('Delete',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSong =
        context.select<AudioPlayerService, bool>((s) => s.currentSong != null);
    return PopScope(
      // System back cancels the selection instead of leaving the page.
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: LiquidBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: _selecting
                ? IconButton(
                    icon: const Icon(Icons.close, color: AppColors.ink),
                    onPressed: _exitSelection,
                  )
                : IconButton(
                    icon: const Icon(Icons.arrow_back, color: AppColors.ink),
                    onPressed: () => Navigator.pop(context),
                  ),
            title: Text(_selecting ? '${_selected.length} selected' : 'History',
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: AppColors.ink)),
            centerTitle: true,
            actions: [
              if (!_selecting)
                IconButton(
                  tooltip: 'Delete all history',
                  onPressed: _history.isEmpty ? null : _clearAll,
                  icon: const Icon(Icons.delete_outline, color: AppColors.ink),
                ),
            ],
          ),
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                AnimatedSwitcher(
                  duration: AppMotion.dur(context, AppMotion.modal),
                  switchInCurve: AppMotion.curve,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: fadeRiseTransition,
                  child: _loading
                      ? const Center(
                          key: ValueKey('history_loading'),
                          child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2)))
                      : _history.isEmpty
                          ? const Center(
                              key: ValueKey('history_empty'),
                              child: Padding(
                                padding: EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.history,
                                        size: 44, color: AppColors.mute),
                                    SizedBox(height: 12),
                                    Text('No listening history',
                                        style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.ink)),
                                    SizedBox(height: 6),
                                    Text('Songs you play will appear here',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: AppColors.inkSoft)),
                                  ],
                                ),
                              ),
                            )
                          : ListView.builder(
                              key: const ValueKey('history_list'),
                              padding: EdgeInsets.only(
                                  left: 8,
                                  right: 8,
                                  top: 8,
                                  bottom: (hasSong ? 190 : 120) +
                                      (_selecting ? 90 : 0)),
                              physics: const BouncingScrollPhysics(),
                              itemCount: _history.length,
                              itemBuilder: (_, i) {
                                final s = _history[i];
                                final selected = _selected.contains(i);
                                return MotionPress(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: _selecting
                                        ? () => _toggle(i)
                                        : () => playSongs(context,
                                            song: s, queue: _history, index: i),
                                    onLongPress: () => _startSelection(i),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? Colors.white
                                                .withValues(alpha: 0.06)
                                            : null,
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 6, horizontal: 4),
                                      child: Row(
                                        children: [
                                          Artwork(s.thumbnailUrl,
                                              size: 48, radius: 10),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(s.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 14,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        color: AppColors.ink)),
                                                Text(s.artist,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        color:
                                                            AppColors.inkSoft,
                                                        fontSize: 12)),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(formatClock(s.duration),
                                              style: const TextStyle(
                                                  color: AppColors.mute,
                                                  fontSize: 12)),
                                          const SizedBox(width: 4),
                                          if (_selecting)
                                            SelectionCheck(selected)
                                          else
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  tooltip:
                                                      'Remove from history',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  icon: const Icon(
                                                      Icons.delete_outline,
                                                      size: 20,
                                                      color: AppColors.mute),
                                                  onPressed: () => _remove(s),
                                                ),
                                                SongMenuButton(
                                                  song: s,
                                                  queue: _history,
                                                  index: i,
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
                if (hasSong)
                  const Positioned(
                      left: 16, right: 16, bottom: 8, child: MiniPlayer()),
                if (_selecting)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: hasSong ? 100 : 16,
                    child: _selectionBar(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
