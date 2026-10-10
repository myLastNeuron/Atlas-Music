import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'artwork.dart';
import 'play_helper.dart';

/// Canonical per-song actions, shared by every list that shows a song so the
/// 3-dot menu behaves identically everywhere. The menu pops out of the
/// button itself: it is positioned against the button's rect and scales +
/// fades from that corner using the app's shared motion curve.
Future<void> showSongActions(
  BuildContext context, {
  required Song song,
  List<Song>? queue,
  int? index,
  String? queueOrigin,
  Rect? anchor,
  Future<void> Function()? onRemoveFromPlaylist,
  Future<void> Function()? onRemoveFromDownloads,
}) async {
  final storage = StorageService.instance;
  bool liked = false;
  bool downloaded = false;
  try {
    liked = await storage.isSongLiked(song.id);
    downloaded =
        (await storage.getDownloadedSongs()).any((s) => s.id == song.id);
  } catch (_) {
    // Best-effort: menu still works with default state.
  }
  if (!context.mounted) return;

  final media = MediaQuery.of(context);
  final size = media.size;
  final safe = media.padding;
  final rect = anchor ?? Rect.fromLTWH(size.width - 56, size.height / 2, 0, 0);
  final margin = EdgeInsets.only(top: safe.top + 8, bottom: safe.bottom + 8);
  // Below the screen midpoint there is no room underneath, so the menu
  // sprouts upward; its scale origin follows the same corner.
  final openUp = rect.center.dy > size.height / 2;
  final origin = openUp ? Alignment.bottomRight : Alignment.topRight;

  await showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Song actions',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: AppMotion.modal,
    pageBuilder: (ctx, anim, _) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: AppMotion.curve,
        reverseCurve: Curves.easeInCubic,
      );
      return CustomSingleChildLayout(
        delegate: _AnchoredMenuLayout(anchor: rect, padding: margin),
        child: FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.86, end: 1.0).animate(curved),
            alignment: origin,
            child: _SongActionsCard(
              hostContext: context,
              song: song,
              queue: queue,
              index: index,
              queueOrigin: queueOrigin,
              initialLiked: liked,
              downloaded: downloaded,
              onRemoveFromPlaylist: onRemoveFromPlaylist,
              onRemoveFromDownloads: onRemoveFromDownloads,
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, __, ___, child) => child,
  );
}

/// Anchor-aware placement: right-aligned to the button, below it unless it
/// would overflow the bottom, then above; clamped inside the safe area.
class _AnchoredMenuLayout extends SingleChildLayoutDelegate {
  _AnchoredMenuLayout({required this.anchor, required this.padding});

  final Rect anchor;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: 260,
      maxHeight: constraints.maxHeight - padding.vertical,
    );
  }

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = size.width - childSize.width - padding.right;
    final x = (anchor.right - childSize.width).clamp(padding.left, maxX);

    var y = anchor.bottom + 6;
    if (y + childSize.height > size.height - padding.bottom) {
      final above = anchor.top - 6 - childSize.height;
      y = above >= padding.top
          ? above
          : (size.height - childSize.height - padding.bottom);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AnchoredMenuLayout old) =>
      old.anchor != anchor || old.padding != padding;
}

/// The trailing 3-dot used in list rows. [compact] renders a small
/// translucent circle for overlaying on artwork cards.
class SongMenuButton extends StatelessWidget {
  final Song song;
  final List<Song>? queue;
  final int? index;
  final String? queueOrigin;
  final Future<void> Function()? onRemoveFromPlaylist;
  final Future<void> Function()? onRemoveFromDownloads;
  final bool compact;

  const SongMenuButton({
    super.key,
    required this.song,
    this.queue,
    this.index,
    this.queueOrigin,
    this.onRemoveFromPlaylist,
    this.onRemoveFromDownloads,
    this.compact = false,
  });

  Rect? _anchorFrom(BuildContext context) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    void onPressed() {
      showSongActions(
        context,
        song: song,
        queue: queue,
        index: index,
        queueOrigin: queueOrigin,
        anchor: _anchorFrom(context),
        onRemoveFromPlaylist: onRemoveFromPlaylist,
        onRemoveFromDownloads: onRemoveFromDownloads,
      );
    }

    if (!compact) {
      return IconButton(
        tooltip: 'More options',
        icon: const Icon(Icons.more_vert, size: 20),
        onPressed: onPressed,
      );
    }
    return IconButton(
      tooltip: 'More options',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.more_vert, size: 18, color: Colors.white),
      ),
      onPressed: onPressed,
    );
  }
}

class _SongActionsCard extends StatefulWidget {
  final BuildContext hostContext;
  final Song song;
  final List<Song>? queue;
  final int? index;
  final String? queueOrigin;
  final bool initialLiked;
  final bool downloaded;
  final Future<void> Function()? onRemoveFromPlaylist;
  final Future<void> Function()? onRemoveFromDownloads;

  const _SongActionsCard({
    required this.hostContext,
    required this.song,
    this.queue,
    this.index,
    this.queueOrigin,
    required this.initialLiked,
    required this.downloaded,
    this.onRemoveFromPlaylist,
    this.onRemoveFromDownloads,
  });

  @override
  State<_SongActionsCard> createState() => _SongActionsCardState();
}

class _SongActionsCardState extends State<_SongActionsCard> {
  late bool _liked = widget.initialLiked;

  void _pop() {
    if (mounted) Navigator.pop(context);
  }

  List<Song> get _queue => widget.queue ?? [widget.song];

  int get _index {
    if (widget.index != null) return widget.index!;
    final at = _queue.indexWhere((s) => s.id == widget.song.id);
    return at < 0 ? 0 : at;
  }

  Future<void> _playNow() async {
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    await playSongs(ctx,
        song: widget.song,
        queue: _queue,
        index: _index,
        queueOrigin: widget.queueOrigin);
  }

  Future<void> _playNext() async {
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    final audio = ctx.read<AudioPlayerService>();
    // Nothing playing: there is no "after this" — play it now instead.
    if (audio.currentSong == null) {
      await playSongs(ctx,
          song: widget.song,
          queue: _queue,
          index: _index,
          queueOrigin: widget.queueOrigin);
      return;
    }
    audio.setPlayNext(widget.song);
    messengerOf(ctx).showSnackBar(
      SnackBar(content: Text('Will play next: ${widget.song.title}')),
    );
  }

  Future<void> _addToPlaylist() async {
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    await addSongToPlaylistFlow(ctx, widget.song);
  }

  Future<void> _toggleLike() async {
    final next = !_liked;
    setState(() => _liked = next);
    try {
      await StorageService.instance.toggleLikedSong(widget.song);
    } catch (_) {}
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    messengerOf(ctx).showSnackBar(
      SnackBar(
          content:
              Text(next ? 'Added to Liked Songs' : 'Removed from Liked Songs')),
    );
  }

  Future<void> _download() async {
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    await downloadSongFlow(ctx, widget.song);
  }

  Future<void> _removeFromPlaylist() async {
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    await widget.onRemoveFromPlaylist?.call();
  }

  Future<void> _removeFromDownloads() async {
    _pop();
    final ctx = widget.hostContext;
    if (!ctx.mounted) return;
    await widget.onRemoveFromDownloads?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 250,
        decoration: BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.glassBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  Artwork(widget.song.thumbnailUrl, size: 38, radius: 8),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        Text(widget.song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.inkSoft, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.line, height: 1),
            const SizedBox(height: 4),
            _tile(Icons.play_arrow_rounded, 'Play now', _playNow),
            _tile(Icons.queue_play_next, 'Play next', _playNext),
            _tile(Icons.playlist_add, 'Add to playlist', _addToPlaylist),
            _tile(
              _liked ? Icons.favorite : Icons.favorite_border,
              _liked ? 'Unlike' : 'Like',
              _toggleLike,
            ),
            if (!widget.downloaded)
              _tile(Icons.download_outlined, 'Download', _download),
            if (widget.onRemoveFromPlaylist != null)
              // A downloaded track leaves the app with its local file, so the
              // action reads "Delete" rather than "Remove".
              _tile(
                  widget.downloaded
                      ? Icons.delete_outline
                      : Icons.remove_circle_outline,
                  widget.downloaded
                      ? 'Delete from Playlist'
                      : 'Remove from Playlist',
                  _removeFromPlaylist),
            if (widget.onRemoveFromDownloads != null)
              _tile(Icons.delete_outline, 'Remove from downloads',
                  _removeFromDownloads),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.inkSoft),
            const SizedBox(width: 14),
            Text(label,
                style: const TextStyle(color: AppColors.ink, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// Shared "add to playlist" flow (was duplicated in Search).
Future<void> addSongToPlaylistFlow(BuildContext context, Song song) async {
  final storage = StorageService.instance;
  final playlists = await storage.getPlaylists();
  if (!context.mounted) return;
  if (playlists.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content:
              Text('Create a playlist first from the Home or Library tab')),
    );
    return;
  }
  final chosen = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: AppColors.glass,
      title: const Text('Add to playlist'),
      children: playlists
          .map((p) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, p.id),
                child: Row(
                  children: [
                    const Icon(Icons.queue_music,
                        size: 20, color: AppColors.inkSoft),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500)),
                          Text('${p.songs.length} songs',
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.inkSoft)),
                        ],
                      ),
                    ),
                  ],
                ),
              ))
          .toList(),
    ),
  );
  if (chosen == null) return;
  await storage.addSongToPlaylist(chosen, song);
  if (!context.mounted) return;
  final pl = playlists.firstWhere((p) => p.id == chosen);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Added to "${pl.name}"')),
  );
}

/// Blocking progress dialog. Awaits nothing; call the returned closer once
/// the work finishes (idempotent, safe after the route is gone).
final _noProgress = ValueNotifier<double?>(null);

Future<void> Function() showBlockingProgress(BuildContext context, String message,
    {ValueListenable<double?>? progress}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.glass,
      content: ValueListenableBuilder<double?>(
        valueListenable: progress ?? _noProgress,
        builder: (_, value, __) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(value: value),
            const SizedBox(height: 14),
            Text(value == null
                ? message
                : '$message ${(value * 100).round()}%'),
          ],
        ),
      ),
    ),
  ).whenComplete(() => open = false);
  return () async {
    if (open && navigator.canPop()) navigator.pop();
    open = false;
  };
}

/// Shared single-song download flow: progress dialog + result snackbar.
Future<void> downloadSongFlow(BuildContext context, Song song) async {
  final audio = context.read<AudioPlayerService>();
  final close = showBlockingProgress(context, 'Downloading...',
      progress: audio.downloadProgress);
  final ok = await audio.downloadCurrentSongForSong(song);
  await close();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(ok ? 'Download completed' : 'Download failed')),
  );
}

/// Row-index multi-select state shared by the list screens. Indices point
/// into a frozen snapshot so a background reload cannot shift the target row.
class MultiSelectController {
  bool selecting = false;
  final Set<int> selected = <int>{};

  void start(int i) {
    selecting = true;
    selected
      ..clear()
      ..add(i);
  }

  void toggle(int i) {
    if (!selected.remove(i)) selected.add(i);
    if (selected.isEmpty) selecting = false;
  }

  void exit() {
    selecting = false;
    selected.clear();
  }
}

/// Floating "N selected / Cancel / actions" bar shown in multi-select mode.
class SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final List<Widget> actions;

  const SelectionBar({
    super.key,
    required this.count,
    required this.onCancel,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('$count selected',
                style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
          const SizedBox(width: 4),
          ...actions,
        ],
      ),
    );
  }
}

/// Check/uncheck indicator shown while a list is in multi-select mode.
class SelectionCheck extends StatelessWidget {
  final bool selected;
  const SelectionCheck(this.selected, {super.key});

  @override
  Widget build(BuildContext context) => Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 22,
        color: selected ? AppColors.ink : AppColors.mute,
      );
}
